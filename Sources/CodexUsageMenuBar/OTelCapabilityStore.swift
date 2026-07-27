import Darwin
import Foundation
import Security

enum DescriptorDirectoryError: Error {
    case invalidAbsolutePath
    case missing
    case posix(code: Int32)
    case unsafeComponent
}

enum DescriptorDirectory {
    static func openOrCreate(
        at directory: URL,
        creationMode: mode_t = S_IRWXU
    ) throws -> Int32 {
        try open(
            at: directory,
            createIfMissing: true,
            creationMode: creationMode
        )
    }

    static func openExisting(at directory: URL) throws -> Int32 {
        try open(
            at: directory,
            createIfMissing: false,
            creationMode: S_IRWXU
        )
    }

    private static func open(
        at directory: URL,
        createIfMissing: Bool,
        creationMode: mode_t
    ) throws -> Int32 {
        guard directory.isFileURL else {
            throw DescriptorDirectoryError.invalidAbsolutePath
        }
        let path = directory.path
        guard path.hasPrefix("/") else {
            throw DescriptorDirectoryError.invalidAbsolutePath
        }
        var components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        components = trustedPlatformAliasExpanded(components)
        guard
            !components.isEmpty,
            components.allSatisfy({ $0 != "." && $0 != ".." })
        else {
            throw DescriptorDirectoryError.invalidAbsolutePath
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw DescriptorDirectoryError.posix(code: errno)
        }

        do {
            for rawComponent in components {
                let component = String(rawComponent)
                var nextDescriptor = openat(
                    currentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        | O_NONBLOCK
                )
                if
                    nextDescriptor < 0,
                    errno == ENOENT,
                    !createIfMissing
                {
                    throw DescriptorDirectoryError.missing
                }
                if nextDescriptor < 0, errno == ENOENT {
                    let creationStatus = mkdirat(
                        currentDescriptor,
                        component,
                        creationMode
                    )
                    if creationStatus != 0, errno != EEXIST {
                        throw DescriptorDirectoryError.posix(code: errno)
                    }
                    if creationStatus == 0, fsync(currentDescriptor) != 0 {
                        throw DescriptorDirectoryError.posix(code: errno)
                    }
                    nextDescriptor = openat(
                        currentDescriptor,
                        component,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                            | O_NONBLOCK
                    )
                }
                guard nextDescriptor >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw DescriptorDirectoryError.unsafeComponent
                    }
                    throw DescriptorDirectoryError.posix(code: errno)
                }

                var metadata = stat()
                guard fstat(nextDescriptor, &metadata) == 0 else {
                    let failure = errno
                    Darwin.close(nextDescriptor)
                    throw DescriptorDirectoryError.posix(code: failure)
                }
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    Darwin.close(nextDescriptor)
                    throw DescriptorDirectoryError.unsafeComponent
                }

                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return currentDescriptor
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func trustedPlatformAliasExpanded(
        _ components: [String]
    ) -> [String] {
        guard let first = components.first else { return components }
        let expectedTargets = [
            "etc": "private/etc",
            "tmp": "private/tmp",
            "var": "private/var",
        ]
        guard let expectedTarget = expectedTargets[first] else {
            return components
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let aliasPath = "/\(first)"
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            aliasPath.withCString { pathPointer in
                Darwin.readlink(
                    pathPointer,
                    pointer.baseAddress!,
                    pointer.count - 1
                )
            }
        }
        guard count > 0, Int(count) < buffer.count else {
            return components
        }
        let actualTarget = buffer.withUnsafeBytes { bytes in
            String(
                decoding: bytes.prefix(Int(count)),
                as: UTF8.self
            )
        }
        guard actualTarget == expectedTarget else {
            return components
        }
        return expectedTarget.split(separator: "/").map(String.init)
            + components.dropFirst()
    }
}

enum OTelCapabilityStore {
    private static let filename = "otel-capability"
    private static let tokenByteCount = 32
    private static let encodedTokenLength = tokenByteCount * 2

    static func loadOrCreate(in storageDirectory: URL) throws -> String {
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try DescriptorDirectory.openOrCreate(
                at: storageDirectory
            )
        } catch DescriptorDirectoryError.invalidAbsolutePath {
            throw OTelCapabilityError.notDirectory
        } catch DescriptorDirectoryError.unsafeComponent {
            throw OTelCapabilityError.notDirectory
        } catch DescriptorDirectoryError.missing {
            throw OTelCapabilityError.notDirectory
        } catch DescriptorDirectoryError.posix(let code) {
            throw OTelCapabilityError.posix(code: code)
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard
            fstat(directoryDescriptor, &directoryMetadata) == 0,
            directoryMetadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw OTelCapabilityError.notDirectory
        }
        guard fchmod(directoryDescriptor, S_IRWXU) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        do {
            return try readWithTransientPublicationRetry(
                from: directoryDescriptor
            )
        } catch OTelCapabilityError.missing {
            return try create(in: directoryDescriptor)
        }
    }

    private static func create(in directoryDescriptor: Int32) throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: tokenByteCount)
        let byteCount = randomBytes.count
        let randomStatus = randomBytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(
                kSecRandomDefault,
                byteCount,
                buffer.baseAddress!
            ) == errSecSuccess
        }
        guard randomStatus else {
            throw OTelCapabilityError.randomGenerationFailed
        }
        let token = randomBytes.map { String(format: "%02x", $0) }.joined()
        let temporaryFilename =
            ".\(filename).\(UUID().uuidString).temporary"
        let descriptor = openat(
            directoryDescriptor,
            temporaryFilename,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryFilename, 0)
            }
        }

        let bytes = Array(token.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw OTelCapabilityError.posix(code: errno)
            }
            written += count
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard fsync(descriptor) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }

        // Atomically publish only the fully written and synced inode, without
        // ever giving it two names. RENAME_EXCL also keeps concurrent creators
        // from replacing the first complete capability.
        let publishStatus = renameatx_np(
            directoryDescriptor,
            temporaryFilename,
            directoryDescriptor,
            filename,
            UInt32(RENAME_EXCL)
        )
        guard publishStatus == 0 else {
            let publishError = errno
            if publishError == EEXIST {
                return try readWithTransientPublicationRetry(
                    from: directoryDescriptor
                )
            }
            throw OTelCapabilityError.posix(code: publishError)
        }
        shouldRemoveTemporaryFile = false

        var publishedMetadata = stat()
        guard fstat(descriptor, &publishedMetadata) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard
            publishedMetadata.st_mode & S_IFMT == S_IFREG,
            publishedMetadata.st_nlink == 1,
            publishedMetadata.st_size == off_t(encodedTokenLength)
        else {
            throw OTelCapabilityError.changedDuringRead
        }
        try requirePathIdentity(
            publishedMetadata,
            named: filename,
            in: directoryDescriptor
        )
        guard fsync(directoryDescriptor) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        return token
    }

    private static func readWithTransientPublicationRetry(
        from directoryDescriptor: Int32
    ) throws -> String {
        // A bounded retry preserves compatibility with a process that was
        // already publishing via an older build. New publications use an
        // exclusive atomic rename and never create a two-link window.
        for attempt in 0..<64 {
            do {
                return try read(from: directoryDescriptor)
            } catch OTelCapabilityError.unsafeHardLink {
                if attempt < 63 {
                    _ = Darwin.usleep(1_000)
                }
            }
        }
        if try recoverInterruptedLegacyPublication(
            in: directoryDescriptor
        ) {
            return try read(from: directoryDescriptor)
        }
        throw OTelCapabilityError.unsafeHardLink
    }

    private static func recoverInterruptedLegacyPublication(
        in directoryDescriptor: Int32
    ) throws -> Bool {
        let publishedDescriptor = openat(
            directoryDescriptor,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard publishedDescriptor >= 0 else {
            if errno == ENOENT {
                return false
            }
            throw OTelCapabilityError.posix(code: errno)
        }
        defer { Darwin.close(publishedDescriptor) }

        var publishedMetadata = stat()
        guard fstat(publishedDescriptor, &publishedMetadata) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard
            publishedMetadata.st_mode & S_IFMT == S_IFREG,
            publishedMetadata.st_mode & mode_t(0o777) == mode_t(0o600),
            publishedMetadata.st_nlink == 2,
            publishedMetadata.st_size == off_t(encodedTokenLength)
        else {
            return false
        }
        var publishedPathMetadata = stat()
        guard
            fstatat(
                directoryDescriptor,
                filename,
                &publishedPathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            publishedPathMetadata.st_mode & S_IFMT == S_IFREG,
            publishedPathMetadata.st_dev == publishedMetadata.st_dev,
            publishedPathMetadata.st_ino == publishedMetadata.st_ino,
            publishedPathMetadata.st_nlink == 2,
            publishedPathMetadata.st_size == publishedMetadata.st_size
        else {
            return false
        }

        let duplicateDirectoryDescriptor = Darwin.dup(
            directoryDescriptor
        )
        guard duplicateDirectoryDescriptor >= 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard let directory = fdopendir(duplicateDirectoryDescriptor) else {
            let failure = errno
            Darwin.close(duplicateDirectoryDescriptor)
            throw OTelCapabilityError.posix(code: failure)
        }
        defer { closedir(directory) }

        var matchingTemporaryNames: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    throw OTelCapabilityError.posix(code: errno)
                }
                break
            }
            guard
                let name = directoryEntryName(entry),
                isLegacyTemporaryFilename(name)
            else {
                continue
            }

            var temporaryMetadata = stat()
            guard
                fstatat(
                    directoryDescriptor,
                    name,
                    &temporaryMetadata,
                    AT_SYMLINK_NOFOLLOW
                ) == 0
            else {
                if errno == ENOENT {
                    continue
                }
                throw OTelCapabilityError.posix(code: errno)
            }
            if
                temporaryMetadata.st_mode & S_IFMT == S_IFREG,
                temporaryMetadata.st_dev == publishedMetadata.st_dev,
                temporaryMetadata.st_ino == publishedMetadata.st_ino
            {
                matchingTemporaryNames.append(name)
            }
        }
        guard matchingTemporaryNames.count == 1 else {
            return false
        }

        let temporaryName = matchingTemporaryNames[0]
        var currentPublishedMetadata = stat()
        var currentTemporaryMetadata = stat()
        guard
            fstat(
                publishedDescriptor,
                &currentPublishedMetadata
            ) == 0,
            fstatat(
                directoryDescriptor,
                temporaryName,
                &currentTemporaryMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            currentPublishedMetadata.st_dev == publishedMetadata.st_dev,
            currentPublishedMetadata.st_ino == publishedMetadata.st_ino,
            currentPublishedMetadata.st_nlink == 2,
            currentTemporaryMetadata.st_mode & S_IFMT == S_IFREG,
            currentTemporaryMetadata.st_dev == publishedMetadata.st_dev,
            currentTemporaryMetadata.st_ino == publishedMetadata.st_ino
        else {
            return false
        }
        guard
            unlinkat(
                directoryDescriptor,
                temporaryName,
                0
            ) == 0
        else {
            throw OTelCapabilityError.posix(code: errno)
        }

        var recoveredMetadata = stat()
        guard
            fstat(publishedDescriptor, &recoveredMetadata) == 0,
            recoveredMetadata.st_dev == publishedMetadata.st_dev,
            recoveredMetadata.st_ino == publishedMetadata.st_ino,
            recoveredMetadata.st_nlink == 1
        else {
            throw OTelCapabilityError.changedDuringRead
        }
        try requirePathIdentity(
            recoveredMetadata,
            named: filename,
            in: directoryDescriptor
        )
        guard fsync(directoryDescriptor) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        return true
    }

    private static func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> String? {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXNAMLEN) + 1
            ) {
                String(validatingCString: $0)
            }
        }
    }

    private static func isLegacyTemporaryFilename(
        _ name: String
    ) -> Bool {
        let prefix = ".\(filename)."
        let suffix = ".temporary"
        guard
            name.hasPrefix(prefix),
            name.hasSuffix(suffix),
            name.count > prefix.count + suffix.count
        else {
            return false
        }
        let identifierStart = name.index(
            name.startIndex,
            offsetBy: prefix.count
        )
        let identifierEnd = name.index(
            name.endIndex,
            offsetBy: -suffix.count
        )
        return UUID(
            uuidString: String(name[identifierStart..<identifierEnd])
        ) != nil
    }

    private static func read(from directoryDescriptor: Int32) throws -> String {
        let descriptor = openat(
            directoryDescriptor,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw OTelCapabilityError.missing
            }
            throw OTelCapabilityError.posix(code: errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw OTelCapabilityError.notRegularFile
        }
        guard metadata.st_nlink == 1 else {
            throw OTelCapabilityError.unsafeHardLink
        }
        guard metadata.st_size == off_t(encodedTokenLength) else {
            throw OTelCapabilityError.invalidToken
        }
        try requirePathIdentity(
            metadata,
            named: filename,
            in: directoryDescriptor
        )

        var bytes = [UInt8](
            repeating: 0,
            count: encodedTokenLength + 1
        )
        var byteCount = 0
        while byteCount < bytes.count {
            let remainingByteCount = bytes.count - byteCount
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: byteCount),
                    remainingByteCount
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw OTelCapabilityError.posix(code: errno)
            }
            guard count > 0 else { break }
            byteCount += count
        }
        guard
            byteCount == encodedTokenLength,
            let token = String(
                bytes: bytes.prefix(byteCount),
                encoding: .utf8
            ),
            token.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw OTelCapabilityError.invalidToken
        }
        var metadataAfterRead = stat()
        guard fstat(descriptor, &metadataAfterRead) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard
            metadataAfterRead.st_mode & S_IFMT == S_IFREG,
            metadataAfterRead.st_nlink == 1,
            metadataAfterRead.st_dev == metadata.st_dev,
            metadataAfterRead.st_ino == metadata.st_ino,
            metadataAfterRead.st_size == metadata.st_size,
            metadataAfterRead.st_mtimespec.tv_sec
                == metadata.st_mtimespec.tv_sec,
            metadataAfterRead.st_mtimespec.tv_nsec
                == metadata.st_mtimespec.tv_nsec
        else {
            throw OTelCapabilityError.changedDuringRead
        }
        try requirePathIdentity(
            metadataAfterRead,
            named: filename,
            in: directoryDescriptor
        )
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw OTelCapabilityError.posix(code: errno)
        }
        return token
    }

    private static func requirePathIdentity(
        _ expected: stat,
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        var pathMetadata = stat()
        guard
            fstatat(
                directoryDescriptor,
                name,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            throw OTelCapabilityError.posix(code: errno)
        }
        guard
            pathMetadata.st_mode & S_IFMT == S_IFREG,
            pathMetadata.st_nlink == 1,
            pathMetadata.st_dev == expected.st_dev,
            pathMetadata.st_ino == expected.st_ino,
            pathMetadata.st_size == expected.st_size
        else {
            throw OTelCapabilityError.changedDuringRead
        }
    }
}

enum OTelCapabilityError: LocalizedError {
    case changedDuringRead
    case invalidToken
    case missing
    case notDirectory
    case notRegularFile
    case posix(code: Int32)
    case randomGenerationFailed
    case unsafeHardLink

    var errorDescription: String? {
        switch self {
        case .changedDuringRead:
            "Локальный OTel capability был изменён во время чтения."
        case .invalidToken:
            "Локальный OTel capability повреждён; защищённый receiver остановлен."
        case .missing:
            "Файл OTel capability отсутствует."
        case .notDirectory:
            "Каталог хранения OTel capability небезопасен."
        case .notRegularFile:
            "Файл OTel capability не является обычным файлом."
        case .posix(let code):
            String(validatingCString: strerror(code))
                ?? "POSIX error \(code)"
        case .randomGenerationFailed:
            "Не удалось создать криптографически случайный OTel capability."
        case .unsafeHardLink:
            "Файл OTel capability имеет небезопасную жёсткую ссылку."
        }
    }
}

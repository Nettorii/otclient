#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

// Fingerprint of the APK's data.zip, stored next to the extracted game data so a newer APK
// re-extracts instead of running the previous install's scripts. The zip central directory lists
// every entry's name, size and CRC, so hashing it detects any content change without reading
// the whole archive.
namespace AssetStamp
{
    // End-of-central-directory record (22 bytes) plus the longest possible archive comment.
    constexpr size_t MAX_TAIL = 22 + 0xFFFF;

    inline uint32_t readLe(const std::string_view data, const size_t pos, const int bytes)
    {
        uint32_t value = 0;
        for (int i = bytes - 1; i >= 0; --i)
            value = (value << 8) | static_cast<uint8_t>(data[pos + i]);
        return value;
    }

    // Returns {offset, size} of the central directory, given the last bytes of an archive.
    inline std::optional<std::pair<uint64_t, uint64_t>> centralDirectory(const std::string_view tail, const uint64_t archiveSize)
    {
        if (tail.size() < 22 || tail.size() > archiveSize)
            return std::nullopt;

        const uint64_t tailStart = archiveSize - tail.size();
        for (size_t pos = tail.size() - 22 + 1; pos-- > 0;) {
            if (tail.compare(pos, 4, std::string_view("PK\x05\x06", 4)) != 0)
                continue;
            if (pos + 22 + readLe(tail, pos + 20, 2) != tail.size())
                continue;

            const uint64_t size = readLe(tail, pos + 12, 4);
            const uint64_t offset = readLe(tail, pos + 16, 4);
            if (offset + size > tailStart + pos)
                return std::nullopt;
            return std::make_pair(offset, size);
        }
        return std::nullopt;
    }

    inline std::string make(const uint64_t archiveSize, const std::string_view fingerprintBytes)
    {
        uint64_t hash = 14695981039346656037ull;
        for (const char c : fingerprintBytes) {
            hash ^= static_cast<uint8_t>(c);
            hash *= 1099511628211ull;
        }

        static constexpr char digits[] = "0123456789abcdef";
        std::string hex(16, '0');
        for (int i = 15; i >= 0; --i, hash >>= 4)
            hex[i] = digits[hash & 0xF];
        return "v1 " + std::to_string(archiveSize) + " " + hex;
    }

    inline bool needsExtract(const bool initLuaExists, std::string_view storedStamp, const std::string_view currentStamp)
    {
        while (!storedStamp.empty() && (storedStamp.back() == '\n' || storedStamp.back() == '\r'))
            storedStamp.remove_suffix(1);
        return !initLuaExists || storedStamp.empty() || storedStamp != currentStamp;
    }
}

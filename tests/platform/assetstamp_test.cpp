#include <gtest/gtest.h>

#include <framework/platform/assetstamp.h>

#include <cstdint>
#include <string>

namespace {
void putLe(std::string& out, uint64_t value, int bytes)
{
    for (int i = 0; i < bytes; ++i)
        out.push_back(static_cast<char>((value >> (8 * i)) & 0xFF));
}

// A fake archive: local data, a central directory, and an end-of-central-directory record.
std::string archive(const std::string& centralDirectory, const std::string& comment = {})
{
    std::string zip = "PK\x03\x04 local file data ";
    const auto cdOffset = zip.size();
    zip += centralDirectory;
    zip += std::string("PK\x05\x06", 4);
    putLe(zip, 0, 2);
    putLe(zip, 0, 2);
    putLe(zip, 1, 2);
    putLe(zip, 1, 2);
    putLe(zip, centralDirectory.size(), 4);
    putLe(zip, cdOffset, 4);
    putLe(zip, comment.size(), 2);
    zip += comment;
    return zip;
}

std::string stampOf(const std::string& zip)
{
    const std::string_view tail = std::string_view(zip).substr(zip.size() - std::min<size_t>(zip.size(), AssetStamp::MAX_TAIL));
    const auto range = AssetStamp::centralDirectory(tail, zip.size());
    if (!range)
        return AssetStamp::make(zip.size(), tail);
    return AssetStamp::make(zip.size(), std::string_view(zip).substr(range->first, range->second));
}
}

TEST(AssetStamp, FindsTheCentralDirectoryWithAndWithoutComment)
{
    for (const auto& comment : { std::string(), std::string("built by packer") }) {
        const std::string cd = "PK\x01\x02 entry init.lua crc=1234";
        const auto zip = archive(cd, comment);
        const auto range = AssetStamp::centralDirectory(zip, zip.size());
        ASSERT_TRUE(range.has_value());
        EXPECT_EQ(zip.substr(range->first, range->second), cd);
    }
}

TEST(AssetStamp, ReturnsNothingForATruncatedOrForeignBuffer)
{
    EXPECT_FALSE(AssetStamp::centralDirectory("not a zip at all", 16).has_value());
    const auto zip = archive("PK\x01\x02 entry");
    // central directory claims bytes that lie beyond the end record
    std::string broken = zip;
    broken[broken.size() - 6] = static_cast<char>(0x7F);
    EXPECT_FALSE(AssetStamp::centralDirectory(broken, broken.size()).has_value());
}

TEST(AssetStamp, ChangesWhenAnyEntryChecksumChanges)
{
    const auto a = stampOf(archive("PK\x01\x02 entry modules/a.lua crc=1111 entry init.lua crc=2222"));
    const auto b = stampOf(archive("PK\x01\x02 entry modules/a.lua crc=1112 entry init.lua crc=2222"));
    const auto a2 = stampOf(archive("PK\x01\x02 entry modules/a.lua crc=1111 entry init.lua crc=2222"));
    EXPECT_NE(a, b);
    EXPECT_EQ(a, a2);
    EXPECT_FALSE(a.empty());
}

TEST(AssetStamp, ExtractsOnFirstRunOnMissingStampAndOnMismatchOnly)
{
    EXPECT_TRUE(AssetStamp::needsExtract(false, "v1 1 abc", "v1 1 abc"));
    EXPECT_TRUE(AssetStamp::needsExtract(true, "", "v1 1 abc"));
    EXPECT_TRUE(AssetStamp::needsExtract(true, "v1 1 abd", "v1 1 abc"));
    EXPECT_FALSE(AssetStamp::needsExtract(true, "v1 1 abc", "v1 1 abc"));
    EXPECT_FALSE(AssetStamp::needsExtract(true, "v1 1 abc\n", "v1 1 abc"));
}

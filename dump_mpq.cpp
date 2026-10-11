
#include <StormLib.h>
#include <iostream>
#include <vector>
#include <fstream>

int main(int argc, char** argv) {
    HANDLE hMpq;
    if (!SFileOpenArchive(argv[1], 0, MPQ_OPEN_READ_ONLY, &hMpq)) {
        return 1;
    }
    HANDLE hFile;
    if (SFileOpenFileEx(hMpq, argv[2], SFILE_OPEN_FROM_MPQ, &hFile)) {
        DWORD size = SFileGetFileSize(hFile, nullptr);
        std::vector<char> buf(size);
        DWORD read = 0;
        SFileReadFile(hFile, buf.data(), size, &read, nullptr);
        std::cout.write(buf.data(), read);
        SFileCloseFile(hFile);
    }
    SFileCloseArchive(hMpq);
    return 0;
}

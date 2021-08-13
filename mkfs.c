#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <assert.h>
#include <sys/stat.h>

#define HEADER_SIGNATURE (0x706C)
#define VERSION (1)
#define FLAG_DIRECTORY (1 << 0)
#define NAME_SIZE (16)
#define SECTOR_SIZE (0x200)
#define SECTOR_FREE (0)
#define SECTOR_EOF (1)

typedef uint16_t SectorEntry;

typedef struct {
	/* 00 */ char name[NAME_SIZE];
	/* 16 */ uint32_t fileSize;
	/* 20 */ uint16_t firstSector;
	/* 22 */ uint8_t flags;
	/* 23 */ uint8_t checksum;
	/* 24 */ uint8_t unused1[8];
	// 32 bytes.
} DirectoryEntry;

typedef struct {
	// Stored in LBA 1.
	/* 00 */ uint16_t signature;
	/* 02 */ uint16_t version;
	/* 04 */ uint16_t sectorCount;
	/* 06 */ uint16_t unused0;
	/* 08 */ uint16_t sectorTableSize; // In sectors, starting at LBA 2.
	/* 10 */ uint16_t unused1;
	/* 12 */ DirectoryEntry root; 
	// 44 bytes.
	uint8_t unused2[512 - 44];
} Header;

int main(int argc, char **argv) {
	FILE *drive = fopen(argv[1], "r+b");

	Header header = { HEADER_SIGNATURE };
	header.version = VERSION;
	header.sectorCount = atoi(argv[2]);
	header.sectorTableSize = header.sectorCount * sizeof(SectorEntry) / SECTOR_SIZE + 1;

	strcpy(header.root.name, "My Floppy");
	header.root.firstSector = 2 + header.sectorTableSize;

	SectorEntry *sectorTable = (SectorEntry *) calloc(SECTOR_SIZE, header.sectorTableSize);
	sectorTable[0] = sectorTable[1] = sectorTable[header.root.firstSector] = SECTOR_EOF;

	for (uintptr_t i = 0; i < header.sectorTableSize; i++) {
		sectorTable[2 + i] = (i == header.sectorTableSize - 1) ? SECTOR_EOF : (3 + i);
	}

	DirectoryEntry *rootDirectory = (DirectoryEntry *) calloc(1, SECTOR_SIZE);

	DIR *import = opendir(argv[3]);
	struct dirent *entry;
	assert(import);

	int currentSector = header.root.firstSector + 1;
	int currentFile = 0;

	while ((entry = readdir(import))) {
		// Load the file.
		if (entry->d_name[0] == '.') continue;
		char buffer[256];
		sprintf(buffer, "%s/%s", argv[3], entry->d_name);
		struct stat s;
		lstat(buffer, &s);
		if (!S_ISREG(s.st_mode)) continue;
		FILE *input = fopen(buffer, "rb");
		assert(input);
		fseek(input, 0, SEEK_END);
		uint64_t fileSize = ftell(input);
		fseek(input, 0, SEEK_SET);
		void *data = malloc(fileSize);
		fread(data, 1, fileSize, input);
		fclose(input);

		// Setup the root directory entry.
		assert(header.root.fileSize != SECTOR_SIZE);
		header.root.fileSize += sizeof(DirectoryEntry);
		assert(strlen(entry->d_name) < NAME_SIZE);
		strncpy(rootDirectory[currentFile].name, entry->d_name, NAME_SIZE);
		rootDirectory[currentFile].fileSize = fileSize;
		rootDirectory[currentFile].firstSector = currentSector;

		// Calculate the checksum.
		rootDirectory[currentFile].checksum = 0;
		for (uintptr_t i = 0; i < fileSize; i++) rootDirectory[currentFile].checksum ^= ((uint8_t *) data)[i];

		// Write out the file.
		int sectorCount = (fileSize + SECTOR_SIZE) / SECTOR_SIZE;
		fseek(drive, SECTOR_SIZE * currentSector, SEEK_SET);
		fwrite(data, 1, fileSize, drive);

		// Update the sector table.
		for (uintptr_t i = currentSector; i < currentSector + sectorCount - 1; i++) sectorTable[i] = i + 1;
		sectorTable[currentSector + sectorCount - 1] = SECTOR_EOF;

		// Go to the next file.
		// printf("import %d %s of size %d (%d sectors) at sector %d\n", currentFile, buffer, fileSize, sectorCount, currentSector);
		currentSector += sectorCount;
		currentFile++;
		free(data);
	}

	fseek(drive, SECTOR_SIZE, SEEK_SET);
	fwrite(&header, 1, SECTOR_SIZE, drive);
	fwrite(sectorTable, 1, SECTOR_SIZE * header.sectorTableSize, drive);
	fwrite(rootDirectory, 1, SECTOR_SIZE, drive);

	return 0;
}

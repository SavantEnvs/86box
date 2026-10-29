/* libFuzzer harness for 86Box's own CHD disc-image front end, chd_image_open() in src/cdrom/cdrom_chd.c.
 * It drives the code the way cdrom_load() / the emulated drive do: write the image to a temp file, open
 * it (libchdr parses the container, cdrom_chd.c parses the CHT2/CHTR track metadata with sscanf and
 * builds the track table), then call the cdrom_ops_t entry points the emulated drive calls (capacity,
 * TOC, track type, sector reads). The only emulator state it supplies is a zeroed cdrom_t. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <86box/86box.h>
#include <86box/cdrom.h>
#include <86box/crc.h>

extern void *chd_image_open(cdrom_t *dev, const char *path);

/* Emulator globals / logging sinks the compiled-in 86Box sources refer to. */
int chd_precache_level = 0;

void pclog(const char *fmt, ...) { (void) fmt; }
void warning(const char *fmt, ...) { (void) fmt; }

extern uint16_t subq_crc16_table[256]; /* src/cdrom/cdrom.c */

static cdrom_t dev;

/* cdrom_global_init() builds this table once at startup; cdrom_crc16() (sector Q-channel) needs it. */
int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void) argc;
  (void) argv;
  crc16_setup(subq_crc16_table, 0x1021);
  return 0;
}

static int msf_to_lba(const raw_track_info_t *r) {
  return ((int) r->pm * 60 * 75) + ((int) r->ps * 75) + r->pf - 150;
}

static void read_at(const cdrom_ops_t *ops, void *local, uint32_t lba) {
  (void) ops->get_track_type(local, lba);
  (void) ops->read_sector(local, dev.raw_buffer[0], lba);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const char *tmpdir = getenv("TMPDIR");
  char path[4096];
  snprintf(path, sizeof(path), "%s/chdimgXXXXXX", tmpdir ? tmpdir : "/tmp");
  int fd = mkstemp(path);
  if (fd < 0)
    return -1;
  size_t off = 0;
  while (off < size) {
    ssize_t n = write(fd, data + off, size - off);
    if (n <= 0)
      break;
    off += (size_t) n;
  }
  close(fd);

  memset(&dev, 0, sizeof(dev));
  void *local = chd_image_open(&dev, path);
  if (local == NULL) {
    unlink(path);
    return -1;
  }

  const cdrom_ops_t *ops = dev.ops;
  int media = ops->is_dvd(local);
  uint32_t last = ops->get_last_block(local);
  (void) ops->has_audio(local);
  (void) ops->has_data(local);

  /* Table of contents, as cdrom_read_toc*() fetches it. */
  int num = 0;
  uint8_t rti[65536] = {0}; /* the size cdrom.c uses */
  raw_track_info_t *tracks = (raw_track_info_t *) rti;
  ops->get_raw_track_info(local, &num, rti);
  track_info_t ti;
  /* Only tracks the TOC lists: chd_image_get_track_info() indexes rti[-1] for a track number that is
   * not in the TOC (cdrom_chd.c:157), which would halt every input at the first absent number. */
  for (int i = 0; i < num; i++) {
    uint32_t t = tracks[i].point;
    if (t >= 1 && t < 99) {
      (void) ops->get_track_info(local, t, 0, &ti);
      (void) ops->get_track_info(local, t, 1, &ti);
    }
  }
  (void) ops->get_track_info(local, 0xaa, 0, &ti);

  /* The emulator rejects media larger than the drive allows and never reads past the capacity. */
  uint32_t max = media ? DVD_MAX_SECTORS : CD_MAX_SECTORS;
  if (last < max) {
    read_at(ops, local, 0);
    read_at(ops, local, 16);
    read_at(ops, local, last);
    for (int i = 0; i < num; i++) {
      if (tracks[i].point < 1 || tracks[i].point > 99)
        continue;
      int lba = msf_to_lba(&tracks[i]);
      if (lba >= 0 && (uint32_t) lba <= last) {
        read_at(ops, local, (uint32_t) lba);
        if ((uint32_t) lba + 1 <= last)
          read_at(ops, local, (uint32_t) lba + 1);
      }
    }
  }

  ops->close(local);
  unlink(path);
  return 0;
}

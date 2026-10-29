/* Known-answer probe for 86Box's CHD front end (src/cdrom/cdrom_chd.c): open each CHD given on argv with
 * chd_image_open(), then print what the emulated drive would see through the cdrom_ops_t it installs —
 * capacity, media/audio/data flags, the raw TOC, per-track info and a hash of the leading bytes of a few
 * sectors. mayhem/test.sh diffs the output against kat/expected_image.txt, which gen_expected_image.py
 * derives from the fixtures' byte patterns without running any 86Box code. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <86box/86box.h>
#include <86box/cdrom.h>
#include <86box/crc.h>

extern void *chd_image_open(cdrom_t *dev, const char *path);
extern uint16_t subq_crc16_table[256];
int chd_precache_level = 0;
void pclog(const char *fmt, ...) { (void) fmt; }
void warning(const char *fmt, ...) { (void) fmt; }

static cdrom_t dev;

static uint32_t fnv1a(const uint8_t *p, size_t n) {
  uint32_t h = 2166136261u;
  while (n--) {
    h ^= *p++;
    h *= 16777619u;
  }
  return h;
}

static const char *base(const char *p) {
  const char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

int main(int argc, char **argv) {
  crc16_setup(subq_crc16_table, 0x1021);
  for (int a = 1; a < argc; a++) {
    memset(&dev, 0, sizeof(dev));
    void *local = chd_image_open(&dev, argv[a]);
    if (local == NULL) {
      printf("IMAGE %s: rejected\n", base(argv[a]));
      continue;
    }
    const cdrom_ops_t *ops = dev.ops;
    uint32_t last = ops->get_last_block(local);
    printf("IMAGE %s: last_block=%u is_dvd=%d has_audio=%d has_data=%d\n", base(argv[a]), last,
           ops->is_dvd(local), ops->has_audio(local), ops->has_data(local));

    int num = 0;
    uint8_t rti[65536] = {0};
    raw_track_info_t *t = (raw_track_info_t *) rti;
    ops->get_raw_track_info(local, &num, rti);
    for (int i = 0; i < num; i++)
      printf("toc %d: adr_ctl=%02x point=%02x pmsf=%02u:%02u:%02u\n", i, t[i].adr_ctl, t[i].point, t[i].pm,
             t[i].ps, t[i].pf);

    for (int i = 0; i < num; i++) {
      track_info_t ti;
      if (t[i].point >= 1 && t[i].point <= 99 && ops->get_track_info(local, t[i].point, 0, &ti))
        printf("track %d: attr=%02x msf=%02u:%02u:%02u\n", ti.number, ti.attr, ti.m, ti.s, ti.f);
    }

    uint8_t buf[4096];
    for (uint32_t lba = 0; lba <= last && lba < 4; lba++) {
      memset(buf, 0, sizeof(buf));
      int ret = ops->read_sector(local, buf, lba);
      uint8_t type = ops->get_track_type(local, lba);
      size_t len = (type & 0x08) ? 2352 : 2064;
      printf("sector %u: type=%02x ret=%d len=%zu fnv=%08x\n", lba, type, ret, len, fnv1a(buf, len));
    }
    ops->close(local);
  }
  return 0;
}

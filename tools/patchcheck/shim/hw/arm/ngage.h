/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PATCHCHECK_NGAGE_H
#define PATCHCHECK_NGAGE_H
typedef struct NGageFlash NGageFlash;
uint8_t *ngage_flash_data(NGageFlash *f, uint32_t *size);
void ngage_flash_changed(NGageFlash *f, uint32_t off, uint32_t len);
void ngage_apply_rom_patches(const char *path, NGageFlash *cs0, NGageFlash *cs1);
#endif

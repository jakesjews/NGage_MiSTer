/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PATCHCHECK_ERROR_REPORT_H
#define PATCHCHECK_ERROR_REPORT_H
#define info_report(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#define error_report(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#endif

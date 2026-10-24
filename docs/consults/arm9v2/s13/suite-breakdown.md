## crand1.0-3

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 17,706 | 18,787 | -1,081 |
| Retired | 3,450 | 3,450 | +0 |
| Data wait | 7,187 | 6,019 | +1,168 |
| Dependency | 457 | 3,765 | -3,308 |
| Fetch starvation | 2,680 | 1,125 | +1,555 |
| Branch/return recovery | 170 | 380 | -210 |
| Serial/CP15 | 170 | 0 | +170 |
| Replay/reservation | 1,522 | 26 | +1,496 |
| Structural | 2,070 | 4,022 | -1,952 |
| Reset/exception/WFI | 0 | 0 | +0 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 3,450 | 3,450 |
| thumb_continuation | 0 | 0 |
| exception | 0 | 0 |
| dc_uncached | 0 | 0 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 1,294 | 514 |
| dc_miss_busy | 5,893 | 5,505 |
| dc_request_other | 0 | 0 |
| serial_cp15 | 99 | 0 |
| replay | 0 | 26 |
| reservation_recovery | 1,522 | 0 |
| dep_multiply | 82 | 311 |
| dep_shift | 62 | 0 |
| dep_load_use | 182 | 1,849 |
| dep_other | 131 | 1,605 |
| fetch_tlb | 0 | 0 |
| fetch_icache | 2,414 | 671 |
| fetch_redirect | 248 | 438 |
| fetch_other | 18 | 16 |
| branch_a | 28 | 53 |
| branch_decode_early | 141 | 327 |
| return_pc_repair | 1 | 0 |
| serial_refill | 71 | 0 |
| structural_uop | 596 | 773 |
| structural_block | 65 | 503 |
| structural_pipeline | 1,409 | 2,746 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,148 | 1,148 |
| mix_load | 1,025 | 1,025 |
| mix_store | 445 | 445 |
| mix_ldm | 18 | 18 |
| mix_stm | 54 | 54 |
| mix_branch | 595 | 595 |
| mix_multiply | 76 | 76 |
| mix_msr | 19 | 19 |
| mix_mrs | 53 | 53 |
| mix_mrc | 0 | 0 |
| mix_mcr | 0 | 0 |
| mix_swp | 17 | 17 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 0 | 0 |
| condition_failed | 234 | 234 |
| load_words | 1,053 | 1,053 |
| store_words | 986 | 986 |
| branches_taken | 585 | 585 |
| branches_not_taken | 11 | 11 |
| returns | 1 | 1 |
| e29 | 170 | 170 |
| e30 | 230 | 230 |
| e31 | 444 | 442 |
| e32 | 595 | 0 |
| e33 | 510 | 0 |
| retired_dfill | 656 | 874 |
| retired_dlock | 22 | 178 |
| retired_ifill | 1,271 | 1,278 |

## crand1.2-9

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 30,818 | 31,792 | -974 |
| Retired | 3,450 | 3,450 | +0 |
| Data wait | 15,148 | 14,587 | +561 |
| Dependency | 443 | 3,752 | -3,309 |
| Fetch starvation | 7,731 | 5,836 | +1,895 |
| Branch/return recovery | 114 | 250 | -136 |
| Serial/CP15 | 169 | 0 | +169 |
| Replay/reservation | 1,557 | 26 | +1,531 |
| Structural | 2,206 | 3,891 | -1,685 |
| Reset/exception/WFI | 0 | 0 | +0 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 3,450 | 3,450 |
| thumb_continuation | 0 | 0 |
| exception | 0 | 0 |
| dc_uncached | 0 | 0 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 2,290 | 1,261 |
| dc_miss_busy | 12,858 | 13,326 |
| dc_request_other | 0 | 0 |
| serial_cp15 | 106 | 0 |
| replay | 0 | 26 |
| reservation_recovery | 1,557 | 0 |
| dep_multiply | 98 | 333 |
| dep_shift | 78 | 0 |
| dep_load_use | 130 | 1,397 |
| dep_other | 137 | 2,022 |
| fetch_tlb | 0 | 0 |
| fetch_icache | 7,441 | 5,410 |
| fetch_redirect | 267 | 328 |
| fetch_other | 23 | 98 |
| branch_a | 23 | 39 |
| branch_decode_early | 90 | 211 |
| return_pc_repair | 1 | 0 |
| serial_refill | 63 | 0 |
| structural_uop | 596 | 773 |
| structural_block | 34 | 246 |
| structural_pipeline | 1,576 | 2,872 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,148 | 1,148 |
| mix_load | 1,025 | 1,025 |
| mix_store | 445 | 445 |
| mix_ldm | 18 | 18 |
| mix_stm | 54 | 54 |
| mix_branch | 595 | 595 |
| mix_multiply | 76 | 76 |
| mix_msr | 19 | 19 |
| mix_mrs | 53 | 53 |
| mix_mrc | 0 | 0 |
| mix_mcr | 0 | 0 |
| mix_swp | 17 | 17 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 0 | 0 |
| condition_failed | 234 | 234 |
| load_words | 1,053 | 1,053 |
| store_words | 986 | 986 |
| branches_taken | 585 | 585 |
| branches_not_taken | 11 | 11 |
| returns | 1 | 1 |
| e29 | 170 | 170 |
| e30 | 230 | 230 |
| e31 | 433 | 436 |
| e32 | 595 | 0 |
| e33 | 510 | 0 |
| retired_dfill | 681 | 978 |
| retired_dlock | 22 | 182 |
| retired_ifill | 1,360 | 1,324 |

## ctrand1.0-3

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 14,524 | 16,480 | -1,956 |
| Retired | 3,627 | 3,627 | +0 |
| Data wait | 5,308 | 4,042 | +1,266 |
| Dependency | 257 | 2,547 | -2,290 |
| Fetch starvation | 1,525 | 1,250 | +275 |
| Branch/return recovery | 383 | 1,074 | -691 |
| Serial/CP15 | 2 | 0 | +2 |
| Replay/reservation | 1,286 | 27 | +1,259 |
| Structural | 2,136 | 3,913 | -1,777 |
| Reset/exception/WFI | 0 | 0 | +0 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 3,627 | 3,627 |
| thumb_continuation | 0 | 0 |
| exception | 0 | 0 |
| dc_uncached | 0 | 0 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 415 | 4 |
| dc_miss_busy | 4,893 | 4,038 |
| dc_request_other | 0 | 0 |
| serial_cp15 | 2 | 0 |
| replay | 0 | 27 |
| reservation_recovery | 1,286 | 0 |
| dep_multiply | 7 | 31 |
| dep_shift | 21 | 0 |
| dep_load_use | 108 | 1,467 |
| dep_other | 121 | 1,049 |
| fetch_tlb | 0 | 5 |
| fetch_icache | 1,285 | 455 |
| fetch_redirect | 203 | 788 |
| fetch_other | 37 | 2 |
| branch_a | 126 | 727 |
| branch_decode_early | 256 | 347 |
| return_pc_repair | 1 | 0 |
| serial_refill | 0 | 0 |
| structural_uop | 725 | 974 |
| structural_block | 81 | 455 |
| structural_pipeline | 1,330 | 2,484 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,378 | 1,378 |
| mix_load | 832 | 832 |
| mix_store | 469 | 469 |
| mix_ldm | 48 | 48 |
| mix_stm | 90 | 90 |
| mix_branch | 759 | 759 |
| mix_multiply | 11 | 11 |
| mix_msr | 1 | 1 |
| mix_mrs | 39 | 39 |
| mix_mrc | 0 | 0 |
| mix_mcr | 0 | 0 |
| mix_swp | 0 | 0 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 890 | 890 |
| condition_failed | 25 | 25 |
| load_words | 966 | 966 |
| store_words | 1,198 | 1,198 |
| branches_taken | 735 | 735 |
| branches_not_taken | 25 | 25 |
| returns | 39 | 39 |
| e29 | 77 | 77 |
| e30 | 228 | 228 |
| e31 | 207 | 144 |
| e32 | 721 | 0 |
| e33 | 617 | 0 |
| retired_dfill | 416 | 532 |
| retired_dlock | 2 | 74 |
| retired_ifill | 1,089 | 774 |

## ctrand1.2-9

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 22,294 | 23,206 | -912 |
| Retired | 3,627 | 3,627 | +0 |
| Data wait | 10,418 | 8,953 | +1,465 |
| Dependency | 284 | 2,914 | -2,630 |
| Fetch starvation | 3,985 | 2,720 | +1,265 |
| Branch/return recovery | 362 | 1,028 | -666 |
| Serial/CP15 | 2 | 0 | +2 |
| Replay/reservation | 1,353 | 27 | +1,326 |
| Structural | 2,263 | 3,937 | -1,674 |
| Reset/exception/WFI | 0 | 0 | +0 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 3,627 | 3,627 |
| thumb_continuation | 0 | 0 |
| exception | 0 | 0 |
| dc_uncached | 0 | 0 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 783 | 10 |
| dc_miss_busy | 9,635 | 8,943 |
| dc_request_other | 0 | 0 |
| serial_cp15 | 2 | 0 |
| replay | 0 | 27 |
| reservation_recovery | 1,353 | 0 |
| dep_multiply | 7 | 34 |
| dep_shift | 26 | 0 |
| dep_load_use | 106 | 1,463 |
| dep_other | 145 | 1,417 |
| fetch_tlb | 0 | 7 |
| fetch_icache | 3,716 | 1,869 |
| fetch_redirect | 223 | 822 |
| fetch_other | 46 | 22 |
| branch_a | 109 | 680 |
| branch_decode_early | 252 | 348 |
| return_pc_repair | 1 | 0 |
| serial_refill | 0 | 0 |
| structural_uop | 725 | 974 |
| structural_block | 67 | 424 |
| structural_pipeline | 1,471 | 2,539 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,378 | 1,378 |
| mix_load | 832 | 832 |
| mix_store | 469 | 469 |
| mix_ldm | 48 | 48 |
| mix_stm | 90 | 90 |
| mix_branch | 759 | 759 |
| mix_multiply | 11 | 11 |
| mix_msr | 1 | 1 |
| mix_mrs | 39 | 39 |
| mix_mrc | 0 | 0 |
| mix_mcr | 0 | 0 |
| mix_swp | 0 | 0 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 890 | 890 |
| condition_failed | 25 | 25 |
| load_words | 966 | 966 |
| store_words | 1,198 | 1,198 |
| branches_taken | 735 | 735 |
| branches_not_taken | 25 | 25 |
| returns | 39 | 39 |
| e29 | 77 | 77 |
| e30 | 228 | 228 |
| e31 | 196 | 140 |
| e32 | 721 | 0 |
| e33 | 617 | 0 |
| retired_dfill | 447 | 565 |
| retired_dlock | 2 | 74 |
| retired_ifill | 1,160 | 948 |

## mmu_page.0-3

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 29,359 | 31,413 | -2,054 |
| Retired | 4,423 | 4,423 | +0 |
| Data wait | 10,632 | 9,165 | +1,467 |
| Dependency | 279 | 614 | -335 |
| Fetch starvation | 9,309 | 10,991 | -1,682 |
| Branch/return recovery | 108 | 269 | -161 |
| Serial/CP15 | 161 | 224 | -63 |
| Replay/reservation | 579 | 52 | +527 |
| Structural | 3,852 | 5,640 | -1,788 |
| Reset/exception/WFI | 16 | 35 | -19 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 4,423 | 4,423 |
| thumb_continuation | 0 | 0 |
| exception | 16 | 35 |
| dc_uncached | 8,930 | 8,015 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 0 | 0 |
| dc_miss_busy | 0 | 0 |
| dc_request_other | 1,702 | 1,150 |
| serial_cp15 | 153 | 209 |
| replay | 0 | 52 |
| reservation_recovery | 579 | 0 |
| dep_multiply | 0 | 0 |
| dep_shift | 0 | 0 |
| dep_load_use | 145 | 246 |
| dep_other | 134 | 368 |
| fetch_tlb | 33 | 35 |
| fetch_icache | 0 | 0 |
| fetch_redirect | 992 | 2,202 |
| fetch_other | 8,284 | 8,754 |
| branch_a | 69 | 154 |
| branch_decode_early | 17 | 115 |
| return_pc_repair | 22 | 0 |
| serial_refill | 8 | 15 |
| structural_uop | 108 | 168 |
| structural_block | 18 | 84 |
| structural_pipeline | 3,726 | 5,388 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,447 | 1,447 |
| mix_load | 164 | 164 |
| mix_store | 1,394 | 1,394 |
| mix_ldm | 16 | 16 |
| mix_stm | 20 | 20 |
| mix_branch | 1,350 | 1,350 |
| mix_multiply | 0 | 0 |
| mix_msr | 0 | 0 |
| mix_mrs | 12 | 12 |
| mix_mrc | 14 | 14 |
| mix_mcr | 6 | 6 |
| mix_swp | 0 | 0 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 0 | 0 |
| condition_failed | 2 | 2 |
| load_words | 203 | 203 |
| store_words | 1,499 | 1,499 |
| branches_taken | 1,372 | 1,372 |
| branches_not_taken | 2 | 2 |
| returns | 9 | 9 |
| e29 | 0 | 0 |
| e30 | 0 | 0 |
| e31 | 0 | 0 |
| e32 | 1,350 | 0 |
| e33 | 1,294 | 0 |
| retired_dfill | 0 | 0 |
| retired_dlock | 0 | 0 |
| retired_ifill | 0 | 0 |

## mmu_page.2-9

| Class (body only) | V2 | ZAP | V2 minus ZAP |
|---|---:|---:|---:|
| Total | 53,448 | 54,977 | -1,529 |
| Retired | 4,423 | 4,423 | +0 |
| Data wait | 19,280 | 20,546 | -1,266 |
| Dependency | 308 | 1,117 | -809 |
| Fetch starvation | 23,652 | 23,134 | +518 |
| Branch/return recovery | 72 | 172 | -100 |
| Serial/CP15 | 160 | 179 | -19 |
| Replay/reservation | 718 | 39 | +679 |
| Structural | 4,821 | 5,349 | -528 |
| Reset/exception/WFI | 14 | 18 | -4 |

| Fine class | V2 | ZAP |
|---|---:|---:|
| reset | 0 | 0 |
| retired | 4,423 | 4,423 |
| thumb_continuation | 0 | 0 |
| exception | 14 | 18 |
| dc_uncached | 17,578 | 19,042 |
| dc_write_through | 0 | 0 |
| dc_tlb | 0 | 0 |
| dc_lock | 0 | 0 |
| dc_miss_busy | 0 | 0 |
| dc_request_other | 1,702 | 1,504 |
| serial_cp15 | 153 | 172 |
| replay | 0 | 39 |
| reservation_recovery | 718 | 0 |
| dep_multiply | 0 | 0 |
| dep_shift | 0 | 0 |
| dep_load_use | 169 | 246 |
| dep_other | 139 | 871 |
| fetch_tlb | 54 | 59 |
| fetch_icache | 0 | 0 |
| fetch_redirect | 1,655 | 3,061 |
| fetch_other | 21,943 | 20,014 |
| branch_a | 45 | 102 |
| branch_decode_early | 13 | 70 |
| return_pc_repair | 14 | 0 |
| serial_refill | 7 | 7 |
| structural_uop | 108 | 168 |
| structural_block | 4 | 55 |
| structural_pipeline | 4,709 | 5,126 |
| wfi | 0 | 0 |

| Mix / event | V2 | ZAP |
|---|---:|---:|
| mix_other | 1,447 | 1,447 |
| mix_load | 164 | 164 |
| mix_store | 1,394 | 1,394 |
| mix_ldm | 16 | 16 |
| mix_stm | 20 | 20 |
| mix_branch | 1,350 | 1,350 |
| mix_multiply | 0 | 0 |
| mix_msr | 0 | 0 |
| mix_mrs | 12 | 12 |
| mix_mrc | 14 | 14 |
| mix_mcr | 6 | 6 |
| mix_swp | 0 | 0 |
| mix_swi | 0 | 0 |
| mix_unknown | 0 | 0 |
| thumb | 0 | 0 |
| condition_failed | 2 | 2 |
| load_words | 203 | 203 |
| store_words | 1,499 | 1,499 |
| branches_taken | 1,372 | 1,372 |
| branches_not_taken | 2 | 2 |
| returns | 9 | 9 |
| e29 | 0 | 0 |
| e30 | 0 | 0 |
| e31 | 0 | 0 |
| e32 | 1,350 | 0 |
| e33 | 1,294 | 0 |
| retired_dfill | 0 | 0 |
| retired_dlock | 0 | 0 |
| retired_ifill | 0 | 0 |

/* SPDX-License-Identifier: MIT */
/*
 * Binder ABI descriptions for the 32 -> 64 bit translation shim.
 *
 *   kb_u_*  what Android KitKat/API 19 userspace speaks (BINDER_IPC_32BIT, protocol 7):
 *           every pointer / size_t field is 32 bit.
 *   kb_k_*  what the Kobo kernel (4.9.77, no CONFIG_ANDROID_BINDER_IPC_32BIT,
 *           protocol 8) expects: binder_size_t / binder_uintptr_t are 64 bit.
 *
 * The ioctl codes embed sizeof(payload), so every command whose payload
 * differs has a different number on both sides. tests/binder_abi_check_*.c
 * verify all of this against the real uapi header (both configurations).
 */
#ifndef KOBO_BINDER_ABI_H
#define KOBO_BINDER_ABI_H
#include <stdint.h>

#define KB_ASSERT(name, cond) typedef char kb_assert_##name[(cond) ? 1 : -1]

/* ---- ioctl number construction (asm-generic, valid for ARM and x86) ---- */
#define KB_IOC(dir, type, nr, size) \
    (((uint32_t)(dir) << 30) | ((uint32_t)(size) << 16) | \
     ((uint32_t)(type) << 8) | (uint32_t)(nr))
#define KB_DIR_W 1u
#define KB_DIR_R 2u
#define KB_IO(t, nr)         KB_IOC(0, t, nr, 0)
#define KB_IOR(t, nr, sz)    KB_IOC(KB_DIR_R, t, nr, sz)
#define KB_IOW(t, nr, sz)    KB_IOC(KB_DIR_W, t, nr, sz)
#define KB_IOWR(t, nr, sz)   KB_IOC(KB_DIR_R | KB_DIR_W, t, nr, sz)

/* ---- object types (identical on both sides) ---- */
#define KB_PACK(c1, c2, c3, c4) \
    ((((uint32_t)(c1)) << 24) | (((uint32_t)(c2)) << 16) | (((uint32_t)(c3)) << 8) | (uint32_t)(c4))
#define KB_TYPE_LARGE 0x85
#define KB_TYPE_BINDER      KB_PACK('s', 'b', '*', KB_TYPE_LARGE)
#define KB_TYPE_WEAK_BINDER KB_PACK('w', 'b', '*', KB_TYPE_LARGE)
#define KB_TYPE_HANDLE      KB_PACK('s', 'h', '*', KB_TYPE_LARGE)
#define KB_TYPE_WEAK_HANDLE KB_PACK('w', 'h', '*', KB_TYPE_LARGE)
#define KB_TYPE_FD          KB_PACK('f', 'd', '*', KB_TYPE_LARGE)

/* ---- userspace (32 bit) structures ---- */
typedef struct { uint32_t write_size, write_consumed, write_buffer,
                          read_size, read_consumed, read_buffer; } kb_u_write_read;
typedef struct { uint32_t type, flags, binder_or_handle, cookie; } kb_u_obj;
typedef struct { uint32_t target, cookie, code, flags;
                 int32_t sender_pid; uint32_t sender_euid;
                 uint32_t data_size, offsets_size, buffer, offsets; } kb_u_tr;
typedef struct { uint32_t ptr, cookie; } kb_u_ptr_cookie;
typedef struct { int32_t priority; uint32_t ptr, cookie; } kb_u_pri_ptr_cookie;
typedef struct { uint32_t handle, cookie; } kb_u_handle_cookie;

/* ---- kernel (64 bit) structures; uint64_t is 8-byte aligned on ARM EABI ---- */
typedef struct { uint64_t write_size, write_consumed, write_buffer,
                          read_size, read_consumed, read_buffer; } kb_k_write_read;
typedef struct { uint32_t type, flags; uint64_t binder_or_handle, cookie; } kb_k_obj;
typedef struct { uint64_t target, cookie; uint32_t code, flags;
                 int32_t sender_pid; uint32_t sender_euid;
                 uint64_t data_size, offsets_size, buffer, offsets; } kb_k_tr;
typedef struct { uint64_t ptr, cookie; } kb_k_ptr_cookie;
typedef struct { int32_t priority; uint64_t ptr, cookie; } kb_k_pri_ptr_cookie;
/* binder_handle_cookie is __attribute__((packed)) in the kernel uapi header. */
typedef struct __attribute__((packed)) { uint32_t handle; uint64_t cookie; } kb_k_handle_cookie;

KB_ASSERT(u_wr, sizeof(kb_u_write_read) == 24);
KB_ASSERT(u_obj, sizeof(kb_u_obj) == 16);
KB_ASSERT(u_tr, sizeof(kb_u_tr) == 40);
KB_ASSERT(u_pc, sizeof(kb_u_ptr_cookie) == 8);
KB_ASSERT(u_ppc, sizeof(kb_u_pri_ptr_cookie) == 12);
KB_ASSERT(u_hc, sizeof(kb_u_handle_cookie) == 8);
KB_ASSERT(k_wr, sizeof(kb_k_write_read) == 48);
KB_ASSERT(k_obj, sizeof(kb_k_obj) == 24);
KB_ASSERT(k_tr, sizeof(kb_k_tr) == 64);
KB_ASSERT(k_pc, sizeof(kb_k_ptr_cookie) == 16);
KB_ASSERT(k_ppc, sizeof(kb_k_pri_ptr_cookie) == 24);
KB_ASSERT(k_hc, sizeof(kb_k_handle_cookie) == 12);

/* ---- ioctls ---- */
#define KB_U_WRITE_READ  KB_IOWR('b', 1, sizeof(kb_u_write_read))   /* 0xc0186201 */
#define KB_K_WRITE_READ  KB_IOWR('b', 1, sizeof(kb_k_write_read))   /* 0xc0306201 */
#define KB_VERSION       KB_IOWR('b', 9, 4)                         /* 0xc0046209 */
#define KB_PROTOCOL_USER   7
#define KB_PROTOCOL_KERNEL 8

/* ---- BC_* (userspace -> driver), 32 bit and 64 bit numbers ---- */
#define KB_U_BC_TRANSACTION   KB_IOW('c', 0, sizeof(kb_u_tr))
#define KB_K_BC_TRANSACTION   KB_IOW('c', 0, sizeof(kb_k_tr))
#define KB_U_BC_REPLY         KB_IOW('c', 1, sizeof(kb_u_tr))
#define KB_K_BC_REPLY         KB_IOW('c', 1, sizeof(kb_k_tr))
#define KB_BC_ACQUIRE_RESULT  KB_IOW('c', 2, 4)
#define KB_U_BC_FREE_BUFFER   KB_IOW('c', 3, 4)
#define KB_K_BC_FREE_BUFFER   KB_IOW('c', 3, 8)
#define KB_BC_INCREFS         KB_IOW('c', 4, 4)
#define KB_BC_ACQUIRE         KB_IOW('c', 5, 4)
#define KB_BC_RELEASE         KB_IOW('c', 6, 4)
#define KB_BC_DECREFS         KB_IOW('c', 7, 4)
#define KB_U_BC_INCREFS_DONE  KB_IOW('c', 8, sizeof(kb_u_ptr_cookie))
#define KB_K_BC_INCREFS_DONE  KB_IOW('c', 8, sizeof(kb_k_ptr_cookie))
#define KB_U_BC_ACQUIRE_DONE  KB_IOW('c', 9, sizeof(kb_u_ptr_cookie))
#define KB_K_BC_ACQUIRE_DONE  KB_IOW('c', 9, sizeof(kb_k_ptr_cookie))
#define KB_BC_ATTEMPT_ACQUIRE KB_IOW('c', 10, 8)     /* binder_pri_desc, same both */
#define KB_BC_REGISTER_LOOPER KB_IO('c', 11)
#define KB_BC_ENTER_LOOPER    KB_IO('c', 12)
#define KB_BC_EXIT_LOOPER     KB_IO('c', 13)
#define KB_U_BC_REQUEST_DEATH KB_IOW('c', 14, sizeof(kb_u_handle_cookie))
#define KB_K_BC_REQUEST_DEATH KB_IOW('c', 14, sizeof(kb_k_handle_cookie))
#define KB_U_BC_CLEAR_DEATH   KB_IOW('c', 15, sizeof(kb_u_handle_cookie))
#define KB_K_BC_CLEAR_DEATH   KB_IOW('c', 15, sizeof(kb_k_handle_cookie))
#define KB_U_BC_DEAD_DONE     KB_IOW('c', 16, 4)
#define KB_K_BC_DEAD_DONE     KB_IOW('c', 16, 8)

/* ---- BR_* (driver -> userspace) ---- */
#define KB_BR_ERROR           KB_IOR('r', 0, 4)
#define KB_BR_OK              KB_IO('r', 1)
#define KB_U_BR_TRANSACTION   KB_IOR('r', 2, sizeof(kb_u_tr))
#define KB_K_BR_TRANSACTION   KB_IOR('r', 2, sizeof(kb_k_tr))
#define KB_U_BR_REPLY         KB_IOR('r', 3, sizeof(kb_u_tr))
#define KB_K_BR_REPLY         KB_IOR('r', 3, sizeof(kb_k_tr))
#define KB_BR_ACQUIRE_RESULT  KB_IOR('r', 4, 4)
#define KB_BR_DEAD_REPLY      KB_IO('r', 5)
#define KB_BR_TRANSACTION_COMPLETE KB_IO('r', 6)
#define KB_U_BR_INCREFS       KB_IOR('r', 7, sizeof(kb_u_ptr_cookie))
#define KB_K_BR_INCREFS       KB_IOR('r', 7, sizeof(kb_k_ptr_cookie))
#define KB_U_BR_ACQUIRE       KB_IOR('r', 8, sizeof(kb_u_ptr_cookie))
#define KB_K_BR_ACQUIRE       KB_IOR('r', 8, sizeof(kb_k_ptr_cookie))
#define KB_U_BR_RELEASE       KB_IOR('r', 9, sizeof(kb_u_ptr_cookie))
#define KB_K_BR_RELEASE       KB_IOR('r', 9, sizeof(kb_k_ptr_cookie))
#define KB_U_BR_DECREFS       KB_IOR('r', 10, sizeof(kb_u_ptr_cookie))
#define KB_K_BR_DECREFS       KB_IOR('r', 10, sizeof(kb_k_ptr_cookie))
#define KB_U_BR_ATTEMPT_ACQUIRE KB_IOR('r', 11, sizeof(kb_u_pri_ptr_cookie))
#define KB_K_BR_ATTEMPT_ACQUIRE KB_IOR('r', 11, sizeof(kb_k_pri_ptr_cookie))
#define KB_BR_NOOP            KB_IO('r', 12)
#define KB_BR_SPAWN_LOOPER    KB_IO('r', 13)
#define KB_BR_FINISHED        KB_IO('r', 14)
#define KB_U_BR_DEAD_BINDER   KB_IOR('r', 15, 4)
#define KB_K_BR_DEAD_BINDER   KB_IOR('r', 15, 8)
#define KB_U_BR_CLEAR_DEATH_DONE KB_IOR('r', 16, 4)
#define KB_K_BR_CLEAR_DEATH_DONE KB_IOR('r', 16, 8)
#define KB_BR_FAILED_REPLY    KB_IO('r', 17)

#endif

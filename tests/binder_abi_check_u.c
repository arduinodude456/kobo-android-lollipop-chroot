/* SPDX-License-Identifier: MIT */
/* Compile-only check: the userspace-side (32 bit, BINDER_IPC_32BIT) structures and numbers
 * used by the shim equal the real uapi header with BINDER_IPC_32BIT, i.e. KitKat/API 19. */
#define BINDER_IPC_32BIT 1
#include <stddef.h>
#include <linux/android/binder.h>
#include "../native/kobo_binder_abi.h"

KB_ASSERT(wr, sizeof(struct binder_write_read) == sizeof(kb_u_write_read));
KB_ASSERT(wr_wc, offsetof(struct binder_write_read, write_consumed) == offsetof(kb_u_write_read, write_consumed));
KB_ASSERT(wr_rb, offsetof(struct binder_write_read, read_buffer) == offsetof(kb_u_write_read, read_buffer));
KB_ASSERT(obj, sizeof(struct flat_binder_object) == sizeof(kb_u_obj));
KB_ASSERT(obj_f, offsetof(struct flat_binder_object, flags) == offsetof(kb_u_obj, flags));
KB_ASSERT(obj_h, offsetof(struct flat_binder_object, handle) == offsetof(kb_u_obj, binder_or_handle));
KB_ASSERT(obj_c, offsetof(struct flat_binder_object, cookie) == offsetof(kb_u_obj, cookie));
KB_ASSERT(tr, sizeof(struct binder_transaction_data) == sizeof(kb_u_tr));
KB_ASSERT(tr_c, offsetof(struct binder_transaction_data, cookie) == offsetof(kb_u_tr, cookie));
KB_ASSERT(tr_code, offsetof(struct binder_transaction_data, code) == offsetof(kb_u_tr, code));
KB_ASSERT(tr_pid, offsetof(struct binder_transaction_data, sender_pid) == offsetof(kb_u_tr, sender_pid));
KB_ASSERT(tr_euid, offsetof(struct binder_transaction_data, sender_euid) == offsetof(kb_u_tr, sender_euid));
KB_ASSERT(tr_ds, offsetof(struct binder_transaction_data, data_size) == offsetof(kb_u_tr, data_size));
KB_ASSERT(tr_os, offsetof(struct binder_transaction_data, offsets_size) == offsetof(kb_u_tr, offsets_size));
KB_ASSERT(tr_buf, offsetof(struct binder_transaction_data, data.ptr.buffer) == offsetof(kb_u_tr, buffer));
KB_ASSERT(tr_off, offsetof(struct binder_transaction_data, data.ptr.offsets) == offsetof(kb_u_tr, offsets));
KB_ASSERT(pc, sizeof(struct binder_ptr_cookie) == sizeof(kb_u_ptr_cookie));
KB_ASSERT(ppc, sizeof(struct binder_pri_ptr_cookie) == sizeof(kb_u_pri_ptr_cookie));
KB_ASSERT(ppc_p, offsetof(struct binder_pri_ptr_cookie, ptr) == offsetof(kb_u_pri_ptr_cookie, ptr));
KB_ASSERT(hc, sizeof(struct binder_handle_cookie) == sizeof(kb_u_handle_cookie));
KB_ASSERT(hc_c, offsetof(struct binder_handle_cookie, cookie) == offsetof(kb_u_handle_cookie, cookie));

KB_ASSERT(c_wr, BINDER_WRITE_READ == KB_U_WRITE_READ);
KB_ASSERT(c_ver, BINDER_VERSION == KB_VERSION);
KB_ASSERT(c_tr, BC_TRANSACTION == KB_U_BC_TRANSACTION);
KB_ASSERT(c_rep, BC_REPLY == KB_U_BC_REPLY);
KB_ASSERT(c_ar, BC_ACQUIRE_RESULT == KB_BC_ACQUIRE_RESULT);
KB_ASSERT(c_fb, BC_FREE_BUFFER == KB_U_BC_FREE_BUFFER);
KB_ASSERT(c_i, BC_INCREFS == KB_BC_INCREFS);
KB_ASSERT(c_a, BC_ACQUIRE == KB_BC_ACQUIRE);
KB_ASSERT(c_r, BC_RELEASE == KB_BC_RELEASE);
KB_ASSERT(c_d, BC_DECREFS == KB_BC_DECREFS);
KB_ASSERT(c_id, BC_INCREFS_DONE == KB_U_BC_INCREFS_DONE);
KB_ASSERT(c_ad, BC_ACQUIRE_DONE == KB_U_BC_ACQUIRE_DONE);
KB_ASSERT(c_at, BC_ATTEMPT_ACQUIRE == KB_BC_ATTEMPT_ACQUIRE);
KB_ASSERT(c_rl, BC_REGISTER_LOOPER == KB_BC_REGISTER_LOOPER);
KB_ASSERT(c_el, BC_ENTER_LOOPER == KB_BC_ENTER_LOOPER);
KB_ASSERT(c_xl, BC_EXIT_LOOPER == KB_BC_EXIT_LOOPER);
KB_ASSERT(c_rd, BC_REQUEST_DEATH_NOTIFICATION == KB_U_BC_REQUEST_DEATH);
KB_ASSERT(c_cd, BC_CLEAR_DEATH_NOTIFICATION == KB_U_BC_CLEAR_DEATH);
KB_ASSERT(c_dd, BC_DEAD_BINDER_DONE == KB_U_BC_DEAD_DONE);
KB_ASSERT(r_err, BR_ERROR == KB_BR_ERROR);
KB_ASSERT(r_ok, BR_OK == KB_BR_OK);
KB_ASSERT(r_tr, BR_TRANSACTION == KB_U_BR_TRANSACTION);
KB_ASSERT(r_rep, BR_REPLY == KB_U_BR_REPLY);
KB_ASSERT(r_ar, BR_ACQUIRE_RESULT == KB_BR_ACQUIRE_RESULT);
KB_ASSERT(r_dr, BR_DEAD_REPLY == KB_BR_DEAD_REPLY);
KB_ASSERT(r_tc, BR_TRANSACTION_COMPLETE == KB_BR_TRANSACTION_COMPLETE);
KB_ASSERT(r_i, BR_INCREFS == KB_U_BR_INCREFS);
KB_ASSERT(r_a, BR_ACQUIRE == KB_U_BR_ACQUIRE);
KB_ASSERT(r_r, BR_RELEASE == KB_U_BR_RELEASE);
KB_ASSERT(r_d, BR_DECREFS == KB_U_BR_DECREFS);
KB_ASSERT(r_at, BR_ATTEMPT_ACQUIRE == KB_U_BR_ATTEMPT_ACQUIRE);
KB_ASSERT(r_n, BR_NOOP == KB_BR_NOOP);
KB_ASSERT(r_s, BR_SPAWN_LOOPER == KB_BR_SPAWN_LOOPER);
KB_ASSERT(r_f, BR_FINISHED == KB_BR_FINISHED);
KB_ASSERT(r_db, BR_DEAD_BINDER == KB_U_BR_DEAD_BINDER);
KB_ASSERT(r_cd, BR_CLEAR_DEATH_NOTIFICATION_DONE == KB_U_BR_CLEAR_DEATH_DONE);
KB_ASSERT(r_fr, BR_FAILED_REPLY == KB_BR_FAILED_REPLY);
KB_ASSERT(t_b, BINDER_TYPE_BINDER == KB_TYPE_BINDER);
KB_ASSERT(t_wb, BINDER_TYPE_WEAK_BINDER == KB_TYPE_WEAK_BINDER);
KB_ASSERT(t_h, BINDER_TYPE_HANDLE == KB_TYPE_HANDLE);
KB_ASSERT(t_wh, BINDER_TYPE_WEAK_HANDLE == KB_TYPE_WEAK_HANDLE);
KB_ASSERT(t_fd, BINDER_TYPE_FD == KB_TYPE_FD);
KB_ASSERT(proto, BINDER_CURRENT_PROTOCOL_VERSION == KB_PROTOCOL_USER);
/* the numbers seen in the device dmesg: c0186201 (KitKat API 19) vs c0306201 (kernel) */
KB_ASSERT(lit_wr, BINDER_WRITE_READ == 0xc0186201u);
KB_ASSERT(lit_ver, BINDER_VERSION == 0xc0046209u);
int main(void) { return 0; }

/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims для форвард-порта vendor Cvitek TPU driver (soph_tpu)
 * с ядра 5.10 на 6.18. Vendor-исходник из osdrv/interdrv/v2/tpu SDK
 * sipeed/LicheeRV-Nano-Build (HAL "mars" = cv181x/SG2002).
 *
 * Здесь только механические переименования API, которые удобно закрыть
 * макросом без правки тела функций. Содержательные изменения (удаление
 * зависимости от ION, замена неэкспортируемого arch_sync_dma_for_device,
 * class_create 1-арг, .remove возвращает void) сделаны прямо в исходнике,
 * см. соответствующие комментарии "forward-port 6.18".
 *
 * Подключается через ccflags-y += -include $(src)/tpu_kernel_compat.h
 */

#ifndef TPU_KERNEL_COMPAT_H
#define TPU_KERNEL_COMPAT_H

#include <linux/version.h>

/* del_timer_sync удалён в 6.10 (treewide del_timer cleanup), заменён на
 * timer_delete_sync.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
#ifndef del_timer_sync
#define del_timer_sync(t)	timer_delete_sync(t)
#endif
#endif

/* from_timer переименован в timer_container_of в 6.16. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
#ifndef from_timer
#define from_timer(var, callback_timer, timer_fieldname) \
	timer_container_of(var, callback_timer, timer_fieldname)
#endif
#endif

/* PDE_DATA() убран в 5.17, остался строчный pde_data(). */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 17, 0)
#ifndef PDE_DATA
#define PDE_DATA(inode)		pde_data(inode)
#endif
#endif

#endif /* TPU_KERNEL_COMPAT_H */

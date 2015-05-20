/*
 * MCE event pool management in MCE context
 *
 * Copyright (C) 2015 Intel Corp.
 * Author: Chen, Gong <gong.chen@linux.intel.com>
 *
 * This file is licensed under GPLv2.
 */
#include <linux/smp.h>
#include <linux/mm.h>
#include <linux/genalloc.h>
#include <linux/llist.h>
#include "mce-internal.h"

/*
 * printk() is not safe in MCE context. This is a lock-less memory allocator
 * used to save error information organized in a lock-less list.
 *
 * This memory pool is only to be used to save MCE records in MCE context.
 * MCE events are rare so a fixed size memory pool should be enough. Use
 * 2 pages to save MCE events for now (~80 MCE records at most).
 */
#define MCE_POOLSZ	(2 * PAGE_SIZE)

static struct gen_pool *mce_evt_pool;
static LLIST_HEAD(mce_event_llist);
static char genpool_buf[MCE_POOLSZ];

void mce_genpool_process(void)
{
	struct llist_node *head;
	struct mce_evt_llist *node;
	struct mce *mce;

	head = llist_del_all(&mce_event_llist);
	if (!head)
		return;

	head = llist_reverse_order(head);
	llist_for_each_entry(node, head, llnode) {
		mce = &node->mce;
		atomic_notifier_call_chain(&x86_mce_decoder_chain, 0, mce);
		gen_pool_free(mce_evt_pool, (unsigned long)node, sizeof(*node));
	}
}

bool mce_genpool_empty(void)
{
	return llist_empty(&mce_event_llist);
}

bool mce_genpool_add(struct mce *mce)
{
	struct mce_evt_llist *node;

	if (!mce_evt_pool)
		return false;

	node = (void *)gen_pool_alloc(mce_evt_pool, sizeof(*node));
	if (!node) {
		pr_warn_ratelimited("MCE records pool full!\n");
		return false;
	}

	memcpy(&node->mce, mce, sizeof(*mce));
	llist_add(&node->llnode, &mce_event_llist);

	return true;
}

static int mce_genpool_create(void)
{
	struct gen_pool *tmpp;
	int ret = -ENOMEM;

	tmpp = gen_pool_create(ilog2(sizeof(struct mce_evt_llist)), -1);
	if (!tmpp)
		goto out;

	ret = gen_pool_add(tmpp, (unsigned long)genpool_buf, MCE_POOLSZ, -1);
	if (ret) {
		gen_pool_destroy(tmpp);
		goto out;
	}

	mce_evt_pool = tmpp;

out:
	return ret;
}

int mce_genpool_init(void)
{
	/* Just init mce_genpool once. */
	if (mce_evt_pool)
		return 0;

	return mce_genpool_create();
}

/*-------------------------------------------------------------------------
 *
 * transam.h
 *	  postgres transaction access method support code header
 *
 *
 * Portions Copyright (c) 1996-2001, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * $Id: transam.h,v 1.35 2001/05/25 15:45:33 momjian Exp $
 *
 *	 NOTES
 *		Transaction System Version 101 now support proper oid
 *		generation and recording in the variable relation.
 *
 *-------------------------------------------------------------------------
 */
#ifndef TRANSAM_H
#define TRANSAM_H

#include "storage/bufmgr.h"

/* ----------------
 *		transaction system version id
 *
 *		this is stored on the first page of the log, time and variable
 *		relations on the first 4 bytes.  This is so that if we improve
 *		the format of the transaction log after postgres version 2, then
 *		people won't have to rebuild their databases.
 *
 *		TRANS_SYSTEM_VERSION 100 means major version 1 minor version 0.
 *		Two databases with the same major version should be compatible,
 *		even if their minor versions differ.
 * ----------------
 */
#define TRANS_SYSTEM_VERSION	200

/* ----------------
 *		transaction id status values
 *
 *		someday we will use "11" = 3 = XID_COMMIT_CHILD to mean the
 *		commiting of child xactions.
 * ----------------
 */
#define XID_COMMIT			2	/* transaction commited */
#define XID_ABORT			1	/* transaction aborted */
#define XID_INPROGRESS		0	/* transaction in progress */
#define XID_COMMIT_CHILD	3	/* child xact commited */

typedef unsigned char XidStatus;/* (2 bits) */

/* ----------
 *		note: we reserve the first 16384 object ids for internal use.
 *		oid's less than this appear in the .bki files.  the choice of
 *		16384 is completely arbitrary.
 * ----------
 */
#define BootstrapObjectIdData 16384

/* ----------------
 *		BitIndexOf computes the index of the Nth xid on a given block
 * ----------------
 */
#define BitIndexOf(N)	((N) * 2)

/* ----------------
 *		transaction page definitions
 * ----------------
 */
#define TP_DataSize				(BLCKSZ - sizeof(XLogRecPtr))
#define TP_NumXidStatusPerBlock (TP_DataSize * 4)

/* ----------------
 *		LogRelationContents structure
 *
 *		This structure describes the storage of the data in the
 *		first 128 bytes of the log relation.  This storage is never
 *		used for transaction status because transaction id's begin
 *		their numbering at 512.
 *
 *		The first 4 bytes of this relation store the version
 *		number of the transaction system.
 * ----------------
 */
typedef struct LogRelationContentsData
{
	XLogRecPtr	LSN;			/* temp hack: LSN is member of any block */
	/* so should be described in bufmgr */
	int			TransSystemVersion;
} LogRelationContentsData;

typedef LogRelationContentsData *LogRelationContents;

/*
 * VariableCache is placed in shmem and used by
 * backends to get next available XID & OID.
 */
typedef struct VariableCacheData
{
	TransactionId nextXid;		/* next XID to assign */
	Oid			nextOid;		/* next OID to assign */
	uint32		oidCount;		/* OIDs available before must do XLOG work */
} VariableCacheData;

typedef VariableCacheData *VariableCache;

/* ----------------
 *		extern declarations
 * ----------------
 */

/*
 * prototypes for functions in transam/transam.c
 */
extern void InitializeTransactionLog(void);
extern bool TransactionIdDidCommit(TransactionId transactionId);
extern bool TransactionIdDidAbort(TransactionId transactionId);
extern void TransactionIdCommit(TransactionId transactionId);
extern void TransactionIdAbort(TransactionId transactionId);

/* in transam/transsup.c */
extern void AmiTransactionOverride(bool flag);
extern void TransComputeBlockNumber(Relation relation,
			  TransactionId transactionId, BlockNumber *blockNumberOutP);
extern XidStatus TransBlockNumberGetXidStatus(Relation relation,
				BlockNumber blockNumber, TransactionId xid, bool *failP);
extern void TransBlockNumberSetXidStatus(Relation relation,
		   BlockNumber blockNumber, TransactionId xid, XidStatus xstatus,
							 bool *failP);

/* in transam/varsup.c */
extern void GetNewTransactionId(TransactionId *xid);
extern void ReadNewTransactionId(TransactionId *xid);
extern void GetNewObjectId(Oid *oid_return);
extern void CheckMaxObjectId(Oid assigned_oid);

/* ----------------
 *		global variable extern declarations
 * ----------------
 */

/* in transam.c */
extern Relation LogRelation;

extern TransactionId cachedTestXid;
extern XidStatus cachedTestXidStatus;

extern TransactionId NullTransactionId;
extern TransactionId AmiTransactionId;
extern TransactionId FirstTransactionId;

extern int	RecoveryCheckingEnableState;

/* in transsup.c */
extern bool AMI_OVERRIDE;

/* in varsup.c */
extern SPINLOCK OidGenLockId;
extern SPINLOCK XidGenLockId;
extern VariableCache ShmemVariableCache;

#endif	 /* TRAMSAM_H */

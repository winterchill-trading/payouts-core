(** Identifies one line of a payout batch, unique within its batch.

    Validated like every ledger id: 1 to 128 characters from [A-Z a-z 0-9 _ - . : / @ +],
    so it can appear in a ledger reference or key without quoting. *)

include Ledger.Validated_id.S

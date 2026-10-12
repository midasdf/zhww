#!/usr/bin/env bash
#
# Verify that a **local EVM node** accepts the transactions this firmware signs.
#
# This is the EVM counterpart of the Bitcoin Core interop test: instead of comparing against a
# library, a real node is asked to accept our raw transactions and mine them.
#
# Usage:
#   anvil --port 8545 --chain-id 31337 &
#   cd firmware && ./tests/evm_node_check.sh
#
# Environment:
#   RPC       node JSON-RPC endpoint (default http://127.0.0.1:8545)
#   MNEMONIC  mnemonic to sign with (default: anvil's standard test mnemonic)
#   CLI       path to the built CLI (default ./zig-out/bin/zhww)
#
# anvil derives its accounts from `test test ... junk` at m/44'/60'/0'/0/, which is exactly the
# path this firmware uses, so account 0 must match the address we derive.

set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
MNEMONIC="${MNEMONIC:-test test test test test test test test test test test junk}"
CLI="${CLI:-./zig-out/bin/zhww}"
CHAIN_ID=31337
# anvil account 0 and account 1
ACCOUNT0=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
ACCOUNT1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

rpc() {
    curl -s -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- wait for the node -------------------------------------------------------------------------
for _ in $(seq 1 30); do
    if rpc eth_chainId '[]' | grep -q "$(printf '0x%x' "$CHAIN_ID")"; then break; fi
    sleep 1
done
rpc eth_chainId '[]' | grep -q "$(printf '0x%x' "$CHAIN_ID")" \
    || fail "no EVM node answering on $RPC with chain id $CHAIN_ID"

[ -x "$CLI" ] || fail "$CLI not found (run: zig build)"

# --- our key derivation must match the node's account 0 ----------------------------------------
DERIVED=$("$CLI" address --mnemonic "$MNEMONIC" 2>/dev/null || true)
SIGNER=$("$CLI" evm-sign --mnemonic "$MNEMONIC" <<< \
    "{\"chainId\":$CHAIN_ID,\"nonce\":0,\"gasPrice\":2000000000,\"gasLimit\":21000,\"to\":\"$ACCOUNT1\",\"value\":1,\"data\":\"0x\"}" \
    2>&1 >/dev/null | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
[ -n "$SIGNER" ] || fail "could not read the sender address from the CLI"
[ "$(echo "$SIGNER" | tr 'A-F' 'a-f')" = "$ACCOUNT0" ] \
    || fail "derived address $SIGNER does not match the node's account 0 ($ACCOUNT0)"
echo "key derivation matches the node's account 0 ($SIGNER)"

# --- sign three kinds of transaction and have the node accept them ------------------------------
sign() {
    printf '%s' "$1" | "$CLI" evm-sign --mnemonic "$MNEMONIC" 2>/dev/null
}

send() { # $1 = raw tx, prints the tx hash
    local response
    response=$(rpc eth_sendRawTransaction "[\"$1\"]")
    echo "$response" | jq -r '.result // empty' | grep -q '^0x' \
        || fail "node rejected the transaction: $response"
    echo "$response" | jq -r '.result'
}

check_receipt() { # $1 = tx hash, $2 = expected type
    local receipt status tx_type gas
    receipt=$(rpc eth_getTransactionReceipt "[\"$1\"]")
    status=$(echo "$receipt" | jq -r '.result.status')
    tx_type=$(echo "$receipt" | jq -r '.result.type')
    gas=$(echo "$receipt" | jq -r '.result.gasUsed')
    [ "$status" = "0x1" ] || fail "transaction $1 was not successful: $receipt"
    [ "$tx_type" = "$2" ] || fail "transaction $1 has type $tx_type, expected $2"
    echo "  accepted and mined: $1 (status $status, type $tx_type, gasUsed $gas)"
}

echo "legacy (EIP-155):"
LEGACY=$(sign "{\"chainId\":$CHAIN_ID,\"nonce\":0,\"gasPrice\":2000000000,\"gasLimit\":21000,\"to\":\"$ACCOUNT1\",\"value\":1000000000000000000,\"data\":\"0x\"}")
check_receipt "$(send "$LEGACY")" "0x0"

echo "EIP-1559 (type 2):"
EIP1559=$(sign "{\"chainId\":$CHAIN_ID,\"nonce\":1,\"gasLimit\":21000,\"maxFeePerGas\":2000000000,\"maxPriorityFeePerGas\":1000000000,\"to\":\"$ACCOUNT1\",\"value\":1000000000000000000,\"data\":\"0x\"}")
check_receipt "$(send "$EIP1559")" "0x2"

echo "with ERC-20 calldata:"
CALLDATA=$(sign "{\"chainId\":$CHAIN_ID,\"nonce\":2,\"gasLimit\":60000,\"maxFeePerGas\":2000000000,\"maxPriorityFeePerGas\":1000000000,\"to\":\"$ACCOUNT1\",\"value\":0,\"data\":\"0xa9059cbb000000000000000000000000353535353535353535353535353535353535353a0000000000000000000000000000000000000000000000000000000005f5e100\"}")
check_receipt "$(send "$CALLDATA")" "0x2"

# --- a tampered signature must not be able to spend our funds -----------------------------------
CONTROL=$(sign "{\"chainId\":$CHAIN_ID,\"nonce\":3,\"gasPrice\":2000000000,\"gasLimit\":21000,\"to\":\"$ACCOUNT1\",\"value\":1,\"data\":\"0x\"}")
TAMPERED="${CONTROL:0:${#CONTROL}-4}$( [ "${CONTROL: -4:1}" = "0" ] && echo "1${CONTROL: -3}" || echo "0${CONTROL: -3}" )"
if rpc eth_sendRawTransaction "[\"$TAMPERED\"]" | jq -e '.result' >/dev/null; then
    fail "the node accepted a transaction with a tampered signature"
fi
echo "tampered signature rejected by the node"

# --- control: the same transaction with the correct signature is accepted ------------------------
check_receipt "$(send "$CONTROL")" "0x0"
echo "correct signature accepted (control)"

echo "OK: the local EVM node accepts every transaction this firmware signs"

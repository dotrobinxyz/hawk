#!/usr/bin/env bash
# Hawk full-lifecycle rehearsal.
#
# Drives the deployed stack through: register (ETH + USDG) → records →
# primary name → universal resolution → wrap → subdomain → trade → renew
# (wrapper expiry sync) → expiry → grace → premium auction purchase →
# post-auction zero premium re-registration → metadata.
#
# Two names are used: <label> goes through the premium auction in stage 2;
# <label>b sits out the full auction and proves zero premium in stage 3.
#
# Local (anvil, time-warped):
#   ./script/rehearse.sh local all
# Testnet (real waits between stages; timers from the testnet config —
# 1h min duration, 30min grace, 2-day premium decay):
#   HAWK_PK=0x... HAWK_PK2=0x... ./script/rehearse.sh base-sepolia stage1
#   ...wait ~1h30m (expiry + grace)...
#   ./script/rehearse.sh base-sepolia stage2
#   ...wait ~2 days (premium decay)...
#   ./script/rehearse.sh base-sepolia stage3
#
# Requires: foundry (cast), jq. Keys via env; anvil defaults for local.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

NETWORK="${1:?usage: rehearse.sh <network> <stage1|stage2|stage3|all>}"
STAGE="${2:?usage: rehearse.sh <network> <stage1|stage2|stage3|all>}"

DEPLOYMENT="deployments/hawk-${NETWORK}.json"
[ -f "$DEPLOYMENT" ] || { echo "missing $DEPLOYMENT — deploy first"; exit 1; }

if [ "$NETWORK" = "local" ]; then
  RPC="${RPC:-http://127.0.0.1:8545}"
  # For local anvil, export HAWK_PK / HAWK_PK2 (e.g. anvil's well-known dev
  # accounts #0 and #1). No private keys are committed to this repo.
  PK="${HAWK_PK:?set HAWK_PK (funded key; anvil dev account for local)}"
  PK2="${HAWK_PK2:?set HAWK_PK2 (second funded key)}"
  CAN_WARP=1
else
  case "$NETWORK" in
    base-sepolia) RPC="${RPC:-https://base-sepolia-rpc.publicnode.com}" ;;
    base) RPC="${RPC:-https://mainnet.base.org}" ;;
    *) RPC="${RPC:?set RPC for network $NETWORK}" ;;
  esac
  PK="${HAWK_PK:?set HAWK_PK (funded key)}"
  PK2="${HAWK_PK2:?set HAWK_PK2 (second funded key)}"
  CAN_WARP=0
fi

j() { jq -r ".$1" "$DEPLOYMENT"; }
REGISTRAR=$(j HawkBaseRegistrar); CONTROLLER=$(j HawkRegistrarController)
WRAPPER=$(j HawkWrapper); RESOLVER=$(j PublicResolver)
REVERSE=$(j ReverseRegistrar); USDG=$(j usdg); UR=$(j UniversalResolver)

ADDR1=$(cast wallet address "$PK"); ADDR2=$(cast wallet address "$PK2")
SECRET=0x6b7a000000000000000000000000000000000000000000000000000000000001
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
ZEROADDR=0x0000000000000000000000000000000000000000
NODE_HAWK=0x1a9af74db203c4017d8445942e9b64ce93d8bc2ae2eed5b8dcbbb0090690d2b3
STATE="deployments/.rehearsal-${NETWORK}"

send() { cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }
send2() { cast send --rpc-url "$RPC" --private-key "$PK2" "$@" >/dev/null; }
call() { cast call --rpc-url "$RPC" "$@"; }
now() { cast block latest -f timestamp --rpc-url "$RPC"; }

warp_to() { # absolute target timestamp (local only)
  local target=$1 current; current=$(now)
  if [ "$target" -gt "$current" ]; then
    cast rpc evm_increaseTime $((target - current)) --rpc-url "$RPC" >/dev/null
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  fi
}
wait_wall() { # seconds (live chains)
  echo "  waiting ${1}s..."; sleep "$1"
}
advance_to() { # absolute target timestamp
  local target=$1 current; current=$(now)
  [ "$target" -le "$current" ] && return 0
  if [ "$CAN_WARP" = "1" ]; then warp_to "$target"; else
    local diff=$((target - current))
    if [ "$diff" -gt 7200 ]; then
      echo "  target is ${diff}s away — rerun this stage later"; exit 2
    fi
    wait_wall $((diff + 15))
  fi
}

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ FAIL: $1"; exit 1; }
labelhash() { cast keccak "$(printf '%s' "$1")"; }
node_of() { cast keccak "$(cast concat-hex "$NODE_HAWK" "$(labelhash "$1")")"; }
strip() { tr -d '() "' ; }

MIN_DUR=$(call "$CONTROLLER" "MIN_REGISTRATION_DURATION()(uint256)" | awk '{print $1}')
GRACE=$(call "$REGISTRAR" "GRACE_PERIOD()(uint256)" | awk '{print $1}')

tuple() { # label owner duration resolver reverseBits
  echo "(\"$1\",$2,$3,${SECRET},$4,[],$5,${ZERO32})"
}

register_eth() { # label owner duration resolver reverseBits senderPk
  local t; t=$(tuple "$1" "$2" "$3" "$4" "$5")
  local sender=$6
  local c
  c=$(call "$CONTROLLER" "makeCommitment((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))(bytes32)" "$t")
  cast send --rpc-url "$RPC" --private-key "$sender" "$CONTROLLER" "commit(bytes32)" "$c" >/dev/null
  if [ "$CAN_WARP" = "1" ]; then warp_to $(( $(now) + 181 )); else wait_wall 75; fi
  local price total
  price=$(call "$CONTROLLER" "rentPrice(string,uint256)((uint256,uint256))" "$1" "$3" | strip)
  total=$(echo "$price" | awk -F, '{printf "%.0f", $1+$2}')
  cast send --rpc-url "$RPC" --private-key "$sender" --value "$total" "$CONTROLLER" "register((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))" "$t" >/dev/null
}

stage1() {
  local LABEL="${REHEARSAL_LABEL:-rh$(now)}"
  echo "== stage 1: register/records/primary/UR/wrap/sub/trade/renew (label: $LABEL) =="
  echo "   min duration: ${MIN_DUR}s, grace: ${GRACE}s"

  echo "- register '$LABEL.hawk' with resolver + primary (ETH)"
  register_eth "$LABEL" "$ADDR1" "$MIN_DUR" "$RESOLVER" 1 "$PK"
  local id node; id=$(labelhash "$LABEL"); node=$(node_of "$LABEL")
  [ "$(call "$REGISTRAR" "ownerOf(uint256)(address)" "$id")" = "$ADDR1" ] || fail "721 owner"
  pass "ERC-721 minted to registrant"

  echo "- companion name '${LABEL}b.hawk' (USDG payment, no resolver)"
  local t2 c2 quote2
  t2=$(tuple "${LABEL}b" "$ADDR1" "$MIN_DUR" "$ZEROADDR" 0)
  c2=$(call "$CONTROLLER" "makeCommitment((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))(bytes32)" "$t2")
  send "$CONTROLLER" "commit(bytes32)" "$c2"
  if [ "$CAN_WARP" = "1" ]; then warp_to $(( $(now) + 181 )); else wait_wall 75; fi
  send "$USDG" "mint(address,uint256)" "$ADDR1" 2000000000
  send "$USDG" "approve(address,uint256)" "$CONTROLLER" 2000000000
  quote2=$(call "$CONTROLLER" "rentPriceUSDG(string,uint256)((uint256,uint256))" "${LABEL}b" "$MIN_DUR" | strip | awk -F, '{printf "%.0f", $1+$2}')
  send "$CONTROLLER" "registerWithUSDG((string,address,uint256,bytes32,address,bytes[],uint8,bytes32),uint256)" "$t2" "$quote2"
  [ "$(call "$REGISTRAR" "ownerOf(uint256)(address)" "$(labelhash "${LABEL}b")")" = "$ADDR1" ] || fail "USDG registration"
  pass "USDG-paid registration ($quote2 units)"

  echo "- resolver records"
  send "$RESOLVER" "setAddr(bytes32,address)" "$node" "$ADDR1"
  send "$RESOLVER" "setText(bytes32,string,string)" "$node" "url" "https://example.invalid"
  [ "$(call "$RESOLVER" "addr(bytes32)(address)" "$node")" = "$ADDR1" ] || fail "addr record"
  pass "addr + text records resolve"

  echo "- reverse resolution"
  local revnode
  revnode=$(call "$REVERSE" "node(address)(bytes32)" "$ADDR1")
  [ "$(call "$RESOLVER" "name(bytes32)(string)" "$revnode" | strip)" = "$LABEL.hawk" ] || fail "primary name"
  pass "primary name live (addr → $LABEL.hawk)"

  echo "- universal resolver"
  local lablen dnsname
  lablen=$(printf '%s' "$LABEL" | wc -c)
  dnsname=$(cast concat-hex "0x$(printf '%02x' "$lablen")" "$(cast from-utf8 "$LABEL")" "0x05726f62696e00")
  call "$UR" "resolve(bytes,bytes)(bytes,address)" "$dnsname" "$(cast calldata 'addr(bytes32)' "$node")" >/dev/null || fail "UR resolve"
  pass "UniversalResolver single-call resolution"

  echo "- wrap, subdomain, trade"
  send "$REGISTRAR" "setApprovalForAll(address,bool)" "$WRAPPER" true
  send "$WRAPPER" "wrapETH2LD(string,address,uint16,address)" "$LABEL" "$ADDR1" 0 "$RESOLVER"
  [ "$(call "$WRAPPER" "ownerOf(uint256)(address)" "$node")" = "$ADDR1" ] || fail "wrap"
  pass "wrapped to ERC-1155"
  send "$WRAPPER" "setSubnodeOwner(bytes32,string,address,uint32,uint64)" "$node" "agent" "$ADDR2" 0 0
  local subnode; subnode=$(cast keccak "$(cast concat-hex "$node" "$(labelhash agent)")")
  [ "$(call "$WRAPPER" "ownerOf(uint256)(address)" "$subnode")" = "$ADDR2" ] || fail "subdomain owner"
  pass "agent.$LABEL.hawk issued to second account"
  send2 "$WRAPPER" "safeTransferFrom(address,address,uint256,uint256,bytes)" "$ADDR2" "$ADDR1" "$subnode" 1 0x
  [ "$(call "$WRAPPER" "ownerOf(uint256)(address)" "$subnode")" = "$ADDR1" ] || fail "subdomain trade"
  pass "subdomain traded (ERC-1155 transfer)"

  echo "- renew wrapped name with USDG; wrapper expiry must sync"
  local exp_before exp_after quote wexp
  exp_before=$(call "$REGISTRAR" "nameExpires(uint256)(uint256)" "$id" | awk '{print $1}')
  quote=$(call "$CONTROLLER" "rentPriceUSDG(string,uint256)((uint256,uint256))" "$LABEL" "$MIN_DUR" | strip | awk -F, '{printf "%.0f", $1}')
  send "$CONTROLLER" "renewWithUSDG(string,uint256,bytes32,uint256)" "$LABEL" "$MIN_DUR" "$ZERO32" "$quote"
  exp_after=$(call "$REGISTRAR" "nameExpires(uint256)(uint256)" "$id" | awk '{print $1}')
  [ "$exp_after" = "$((exp_before + MIN_DUR))" ] || fail "renewal expiry"
  wexp=$(call "$WRAPPER" "getData(uint256)(address,uint32,uint64)" "$node" | sed -n 3p | awk '{print $1}')
  [ "$wexp" = "$((exp_after + GRACE))" ] || fail "wrapper expiry sync ($wexp != $((exp_after + GRACE)))"
  pass "renewed with USDG; wrapper fuse expiry synced"

  echo "- on-chain metadata"
  call "$REGISTRAR" "tokenURI(uint256)(string)" "$id" | grep -q "data:application/json;base64" || fail "tokenURI"
  call "$WRAPPER" "uri(uint256)(string)" "$node" | grep -q "data:application/json;base64" || fail "wrapper uri"
  call "$WRAPPER" "uri(uint256)(string)" "$subnode" | grep -q "data:application/json;base64" || fail "subname uri"
  pass "metadata serving for 721, wrapped 2LD, and subname"

  printf '%s %s\n' "$LABEL" "$exp_after" > "$STATE"
  echo "stage 1 complete. '$LABEL' expires at $exp_after; grace ends $((exp_after + GRACE))."
}

stage2() {
  read -r LABEL EXPIRY < "$STATE"
  echo "== stage 2: expiry → grace → premium purchase (label: $LABEL) =="
  local id node; id=$(labelhash "$LABEL"); node=$(node_of "$LABEL")

  advance_to $((EXPIRY + 1))
  if [ "$(now)" -le "$((EXPIRY + GRACE))" ]; then
    [ "$(call "$CONTROLLER" "available(string)(bool)" "$LABEL")" = "false" ] || fail "should be unavailable in grace"
    pass "expired, in grace: not available"
  else
    echo "  (already past grace — skipping in-grace check)"
  fi

  advance_to $((EXPIRY + GRACE + 30))
  [ "$(call "$CONTROLLER" "available(string)(bool)" "$LABEL")" = "true" ] || fail "should be available after grace"
  local premium
  premium=$(call "$CONTROLLER" "rentPriceUSDG(string,uint256)((uint256,uint256))" "$LABEL" "$MIN_DUR" | strip | awk -F, '{printf "%.0f", $2}')
  [ "$premium" -gt 0 ] || fail "premium should be positive at auction open"
  pass "premium auction live: $premium USDG units (~\$$((premium / 1000000)))"

  echo "- second account buys through the auction (USDG)"
  send2 "$USDG" "mint(address,uint256)" "$ADDR2" 1200000000
  send2 "$USDG" "approve(address,uint256)" "$CONTROLLER" 1200000000
  local t c total
  t=$(tuple "$LABEL" "$ADDR2" "$MIN_DUR" "$ZEROADDR" 0)
  c=$(call "$CONTROLLER" "makeCommitment((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))(bytes32)" "$t")
  send2 "$CONTROLLER" "commit(bytes32)" "$c"
  if [ "$CAN_WARP" = "1" ]; then warp_to $(( $(now) + 181 )); else wait_wall 75; fi
  total=$(call "$CONTROLLER" "rentPriceUSDG(string,uint256)((uint256,uint256))" "$LABEL" "$MIN_DUR" | strip | awk -F, '{printf "%.0f", $1+$2}')
  send2 "$CONTROLLER" "registerWithUSDG((string,address,uint256,bytes32,address,bytes[],uint8,bytes32),uint256)" "$t" "$total"
  [ "$(call "$REGISTRAR" "ownerOf(uint256)(address)" "$id")" = "$ADDR2" ] || fail "auction re-registration owner"
  pass "name re-registered through premium auction (total $total USDG units)"

  local pdays; pdays=$(jq -r '.premiumDays // empty' "script/config/${NETWORK}.json" 2>/dev/null || echo 21)
  printf '%s %s %s\n' "$LABEL" "$EXPIRY" "$(now)" > "$STATE"
  echo "stage 2 complete. Run stage 3 after the ${pdays}-day auction window (for '${LABEL}b')."
}

stage3() {
  read -r LABEL EXPIRY _ < "$STATE"
  echo "== stage 3: zero premium after full decay (label: ${LABEL}b) =="
  local pdays; pdays=$(jq -r '.premiumDays' "script/config/${NETWORK}.json")

  advance_to $((EXPIRY + GRACE + pdays * 86400 + 120))
  [ "$(call "$CONTROLLER" "available(string)(bool)" "${LABEL}b")" = "true" ] || fail "companion should be available"
  local premium base
  premium=$(call "$CONTROLLER" "rentPriceUSDG(string,uint256)((uint256,uint256))" "${LABEL}b" "$MIN_DUR" | strip | awk -F, '{printf "%.0f", $2}')
  [ "$premium" = "0" ] || fail "premium should be zero after ${pdays}d (got $premium)"
  pass "premium fully decayed to zero"

  echo "- re-register companion at pure base price (ETH)"
  register_eth "${LABEL}b" "$ADDR2" "$MIN_DUR" "$ZEROADDR" 0 "$PK2"
  [ "$(call "$REGISTRAR" "ownerOf(uint256)(address)" "$(labelhash "${LABEL}b")")" = "$ADDR2" ] || fail "post-auction re-registration"
  pass "re-registered at base price"
  echo "stage 3 complete — full lifecycle rehearsed: register → wrap → subdomains → trade → renew → expiry → grace → premium auction → decay → re-registration."
}

case "$STAGE" in
  stage1) stage1 ;;
  stage2) stage2 ;;
  stage3) stage3 ;;
  all) stage1; stage2; stage3 ;;
  *) echo "unknown stage $STAGE"; exit 1 ;;
esac

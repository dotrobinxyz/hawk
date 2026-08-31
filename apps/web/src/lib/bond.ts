import { parseAbi } from "viem";

/**
 * HawkBond — bonded operators. Skin in the game behind a fleet: USDC or
 * $HAWK locked behind the 2LD name, visible everywhere, exits through a
 * public 7-day window.
 */
export const HAWK_BOND = "0xE7d326fB486aCC1ae90559fBCe9863503C9DbC83" as const;
export const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;
export const HAWK_TOKEN = "0xb20000000000000000000024008843f777304E01" as const;

export const bondAbi = parseAbi([
  "function bondOf(bytes32 node) view returns (address asset, uint256 amount, uint256 usdValue, uint64 since, uint256 pendingAmount, uint64 unlockAt)",
  "function bondUSDC(uint256 labelhash, uint256 amount)",
  "function bondHAWK(uint256 labelhash, uint256 amount)",
  "function requestWithdraw(uint256 labelhash, uint256 amount)",
  "function claimWithdraw(uint256 labelhash)",
  "function quoteHawkForUsdc(uint256 usdcAmount) view returns (uint256)",
  "function totalHawkBurned() view returns (uint256)",
  "function buybackPool() view returns (uint256)",
]);

export const erc20MinAbi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
]);

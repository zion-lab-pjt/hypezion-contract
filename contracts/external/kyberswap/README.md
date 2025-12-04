# KyberSwap External Contracts

## MetaAggregationRouterV2.sol.bak

This file contains the original KyberSwap MetaAggregationRouterV2 contract implementation.

**Status**: ❌ **NOT COMPILED**

The `.bak` extension excludes this file from Hardhat compilation.

## Why excluded from compilation?

1. **Large File**: 1200+ lines of complex implementation code
2. **Not Needed**: We only need the interface to interact with the deployed router
3. **Compilation Issues**: Uses Solidity 0.8.17 with complex dependencies
4. **Gas Cost**: Unnecessary to compile since router is already deployed

## What we use instead

We created a clean interface at:
```
contracts/interfaces/IMetaAggregationRouterV2.sol
```

This interface contains:
- ✅ All necessary structs (SwapDescriptionV2, SwapExecutionParams)
- ✅ Main `swap()` function signature
- ✅ Relevant events
- ✅ Clean documentation

## Deployed Router Address

**HyperEVM Mainnet/Testnet**: `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5`

## Reference

Original contract kept for reference purposes. Do not modify or compile.

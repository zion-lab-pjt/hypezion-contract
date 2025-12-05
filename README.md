# HypeZion finance - Smart Contracts

This directory contains all smart contract code for the HypeZion finance on HyperEVM.

## Directory Structure

```
├── contracts/           # Smart contract source code
│   ├── core/           # Core finance contracts
│   │   └── HypeZionExchange.sol
│   ├── tokens/         # Token implementations
│   │   ├── HzUSD.sol    # Stablecoin token
│   │   ├── bullHYPE.sol   # Leverage token
│   │   └── StakedHzUSD.sol # ERC4626 vault (shzUSD)
│   ├── integration/    # External integrations
│   │   ├── HyperCoreOracle.sol
│   │   └── KinetiqIntegration.sol
│   └── interfaces/     # Contract interfaces
├── deployments/        # Deployment addresses
├── artifacts/          # Compiled contracts
└── cache/             # Build cache
```

## Setup

```bash
npm install
```

## Compilation

```bash
npx hardhat compile
```

## Key Features

- **Token System**: ERC20 compliant hzUSD and bullHYPE tokens
- **Stability Pool**: ERC4626 vault implementation (shzUSD)
- **Oracle Integration**: HyperCore precompile with fallback support
- **Kinetiq Integration**: Staking through official StakingManager
- **System CR Management**: Three operational modes (Normal, Cautious, Critical)
- **Protocol Intervention**: Automatic hzUSD to bullHYPE conversion when CR < 130%
- **Minimum Staking**: 5 HYPE (adjustable between 0.1-1000 HYPE)

## Security Considerations

- All contracts use OpenZeppelin v5.0 libraries
- Reentrancy protection on all external functions
- Access control for administrative functions
- Pausable mechanism for emergency situations

## License

MIT

# EstimateX Prediction Market Contract

A Clarity smart contract for creating and managing decentralized prediction markets on the Stacks blockchain.

## Core Features

- Create prediction markets with deadlines
- Place bets on binary (yes/no) outcomes
- Resolve markets and distribute winnings
- Track user positions and claims

## Contract Structure

### Data Storage
- `markets`: Stores market details including pools and outcomes
- `user-positions`: Tracks user bets and claim status

### Key Functions

```clarity
create-market (id uint) (question string-ascii) (deadline uint)
buy (id uint) (yes bool) (amount uint)
resolve-market (id uint) (outcome bool)
claim-winnings (id uint)
```

### Read-Only Functions
- `get-market`: Retrieves market details
- `get-user-position`: Gets user's position in a market

## Error Handling

Includes comprehensive error constants (u100-u109) for:
- Market validation
- Transaction failures
- Authorization checks
- State verification

## Security Features

- Creator-only market resolution
- Deadline enforcement
- Single-claim protection
- Safe STX transfers
- Built-in arithmetic safety

## Requirements

- Stacks blockchain
- STX tokens for betting
- Principal authorization for market creation/resolution

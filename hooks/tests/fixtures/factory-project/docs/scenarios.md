# Scenarios

#### CHK-01 — Card: place an order and verify it in the orders service

- **Oracle**: GET /orders/<id> reports placed.

#### CHK-03 — Cancelling the wallet popup returns to checkout without an order

- **Oracle**: GET /orders lists no new order.

#### CHK-06 — Card, registered shopper: place an order

- **Oracle**: GET /orders/<id> reports placed.

#### CHK-98 — a block that exists but fails the lint

- **Purpose**: the block is present but has no oracle line.
- **Expected**: the total is not zero.

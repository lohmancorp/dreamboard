# CB-Next Billing System — Machine Handoff

> **Generated**: 2026-04-06T20:15:00+03:00  
> **Status**: Phases 1–5 backend COMPLETE. Next: Phase 6 (Wallet System).  
> **Alembic Head**: `on4p5q6r7s8t9`

---

## Companion Files (in `docs/`)

These three files contain the full detail — read them for troubleshooting:

| File | Lines | Contents |
|---|---|---|
| `docs/BILLING_AUDIT_V2.md` | 665 | Full architecture audit, all gaps, 8-phase implementation plan, data model diagrams |
| `docs/BILLING_PLAN_MEMORY.md` | 235 | Crash-recovery checkpoint: every file created/modified, every model, every migration, every decision |
| `docs/BILLING_TASKS.md` | 323 | Per-item task tracker: every [x] completed and [ ] deferred item across all phases |

---

## 1. Redis Setup (REQUIRED on new machine)

Redis was added during Phase 5B. The backup restores all code, but Redis needs setup.

### What's Already In Your Code (restored by backup)

- `docker-compose.yml` — Redis 7 Alpine service on port 6379, `redisdata` volume, healthcheck  
- `.env` — `REDIS_URL=redis://localhost:6379/0`  
- `backend/app/config.py` — `REDIS_URL` in Settings class  
- `backend/app/services/rating_engine.py` — Redis connection pool + rating engine  

### Steps On The New Machine

```bash
# 1. Restore backup
./backup/full-backup.sh --restore <archive>

# 2. Start Redis (already in docker-compose.yml)
docker compose up -d redis

# 3. Verify Redis
docker exec cb-next-redis-1 redis-cli ping
# → PONG

# 4. Install Python Redis package
.venv/bin/pip install "redis[hiredis]"

# 5. Verify Python connection
.venv/bin/python -c "import redis; r = redis.Redis(); print(r.ping())"

# 6. Run all migrations
cd backend && ../.venv/bin/python -m alembic upgrade head
# Should end at: on4p5q6r7s8t9

# 7. Start dev
./dev.sh
```

### Troubleshooting

| Issue | Fix |
|---|---|
| `redis.ConnectionError` | `docker compose up -d redis` |
| Port 6379 in use | `brew services stop redis` or change port |
| `ModuleNotFoundError: redis` | `.venv/bin/pip install "redis[hiredis]"` |
| Alembic error | `.venv/bin/python -m alembic current` to check state |

---

## 2. What We Built — Phase-by-Phase Summary

### Phase 1: Foundation (COMPLETE)

**1A. Event Sourcing Infrastructure**
- Created `BillingEvent` model — append-only event store
- Created `emit_event()` utility in `backend/app/services/event_service.py`
- Wired into 11 mutations: create/update/delete offer, set offer items, create/cancel subscription, void/finalize invoice, customer CRUD
- GQL query: `change_log(entity_type, entity_id)`
- Frontend: reusable `ChangeLog.vue` component added to Offer, Subscription, and Customer detail views
- Migration: `ba1b2c3d4e5f6`

**1B. Subscription Tariff / Price Lock**
- Created `SubscriptionTariff` model — snapshots full offer state at purchase time
- `create_subscription` creates tariff with `snapshot_offer_for_tariff()`
- `generate_invoice()` reads prices from tariff, not live offer → **fixes critical price-leak bug**
- `billing_engine.py` refactored with `TariffOfferProxy`, `TariffItemProxy`
- Migration: `cb2d3e4f5g6h7`

**1C. Multi-Currency Foundation**
- Added `base_currency` to Account, `pricing_currency` to Offer
- Created `CurrencyRate` model for FX rate storage
- Invoice stores `base_currency_amount_cents` + `fx_rate_to_base` for normalized reporting
- GQL CRUD for currency rates
- Migration: `dc3e4f5g6h7i8`

**1D. Offer Version Auto-Increment**
- `_update_offer()` auto-bumps: major (1.0→2.0) for pricing, minor (1.0→1.1) for metadata
- Version field removed from UI (read-only display)

**1E. Invoice Immutability & Credit Notes**
- Immutability guard: blocks mutations on non-draft invoices
- Sequential invoice numbers: `INV-YYYY-NNNN` per account
- Created `CreditNote` + `CreditNoteLineItem` models
- `issue_credit_note()` — full or partial credit with auto line items
- GQL mutation + query
- Migration: `ed4f5g6h7i8j9`

**1F. Configurable Commitment Terms**
- Created `CommitmentTermDefinition` model — replaces hard-coded MTM/1Y
- Created `OfferTermPrice` model — dynamic pricing per term
- Seeded: MTM, Quarterly, 1Y Monthly, 1Y Annual, 2Y, 3Y
- Refactored: `billing_engine.py`, `billing_scheduler.py`, `create_subscription`, tariff snapshots
- Migration: `fe5g6h7i8j9k0`

### Phase 2: Revenue Recognition & Contracts (COMPLETE)

**2A. Contract Model**
- Created `Contract` + `ContractAmendment` models
- Auto-creates contract on subscription creation (TCV/ACV calculated)
- GQL queries for contracts
- Migration: `gf6h7i8j9k0l1`

**2B. Revenue Recognition Engine**
- Created `RevenueRecognitionRule`, `RevenueSchedule`, `JournalEntry` models
- 4 recognition methods: straight-line, usage-based, point-in-time, milestone
- Created `backend/app/services/revenue_service.py` — schedule generation, daily processor, amendment regeneration
- GQL queries + mutations for rev rec
- Migration: `hg7i8j9k0l1m2`

### Phase 3: Offer Lifecycle (COMPLETE)

**3A. Offer Effective Date & Price Scheduling**
- Added `effective_date` to Offer, created `OfferPriceSchedule` model
- Created `backend/app/services/offer_scheduler.py` — `activate_pending_offers()`, `apply_scheduled_price_changes()`
- GQL mutations for scheduling
- Migration: `ih8j9k0l1m2n3`

**3B. Subscription Sync Engine**
- Created `SubscriptionSyncRequest` model
- Created `backend/app/services/sync_service.py` — 4 scopes (product_info, resources, amounts, pricing) × 5 timings (immediately, next_month, next_billing_period, next_renewal, effective_date)
- Background job: `process_pending_sync_requests()`
- Migration: `ji9k0l1m2n3o4`

### Phase 4: Upgrade/Downgrade Paths & Proration (BACKEND COMPLETE)

**4A. Transition Path Configuration**
- Created `OfferTransitionPath` model — direction, proration config, timing, customer visibility
- GQL CRUD
- Migration: `kj0l1m2n3o4p5`

**4B. Proration Engine**
- `transition_subscription` mutation: validate path → calculate proration → credit note → update tariff → contract amendment → revenue schedule regen → events
- Proration types: daily_prorate, full_credit, no_prorate
- Created `PendingTransition` model + `backend/app/services/transition_scheduler.py` for deferred timing
- Migration: `lk1m2n3o4p5q6`

### Phase 5: Usage Engine & Exhaustion (BACKEND COMPLETE)

**5A. Optional Item Durability**
- Added `optional_durability` to OfferItem (persistent/one_time/till_consumed)
- Created `SubscriptionOptionalItem` model
- Created `backend/app/services/optional_item_service.py` — purchase, consume, expire, reset, invoice lines
- GQL queries + mutations
- Migration: `ml2n3o4p5q6r7`

**5B. Real-Time Rating Engine (50ms SLA)**
- **Redis 7** added to Docker stack
- Created `backend/app/services/rating_engine.py`
- Redis counters: `usage:{sub_id}:{item_id}` → hash `{used, included, optional_remaining}`
- `POST /api/v1/usage` → Redis HINCRBY → PG write → return remaining
- `GET /api/v1/usage/summary/{subscription_id}` — real-time from Redis
- Functions: `rate_usage()`, `initialize_counters()`, `reset_counters_for_subscription()`, `update_optional_remaining()`

**5C. Usage Exhaustion Policies**
- Added `exhaustion_policy` to OfferItem (block/offer_optional/offer_upgrade/notify_only)
- When exhausted, response includes: `exhaustion_action`, `available_optional_items`, `available_upgrades`, `reset_date`
- Events: `usage.exhausted`, `usage.optional_offered`, `usage.upgrade_offered`
- Migration: `nm3o4p5q6r7s8`

**5D. Generic Cost Items**
- Created `CostItem` model (16 columns)
- Created `backend/app/services/cost_engine.py` — `get_cost_summary()`, `calculate_margin()`, `allocate_costs_to_subscription()`
- GQL CRUD + `cost_summary` + `margin` queries
- Migration: `on4p5q6r7s8t9`

---

## 3. Migration Chain

```
cc3d4e5f6g7h (pre-existing head)
  → ba1b2c3d4e5f6  (1A: billing_events)
  → cb2d3e4f5g6h7  (1B: subscription_tariffs)
  → dc3e4f5g6h7i8  (1C: multi-currency)
  → ed4f5g6h7i8j9  (1E: invoice immutability + credit notes)
  → fe5g6h7i8j9k0  (1F: commitment terms)
  → gf6h7i8j9k0l1  (2A: contracts)
  → hg7i8j9k0l1m2  (2B: revenue recognition)
  → ih8j9k0l1m2n3  (3A: offer scheduling)
  → ji9k0l1m2n3o4  (3B: subscription sync)
  → kj0l1m2n3o4p5  (4A: transition paths)
  → lk1m2n3o4p5q6  (4B: pending transitions)
  → ml2n3o4p5q6r7  (5A: optional durability)
  → nm3o4p5q6r7s8  (5C: exhaustion policy)
  → on4p5q6r7s8t9  (5D: cost items) ← HEAD
```

---

## 4. Schema Inheritance Chain

```
Query
  → QueryWithBillingEvents (1A)
  → QueryWithCurrency (1C)
  → QueryWithCreditNotes (1E)
  → QueryWithCommitmentTerms (1F)
  → QueryWithContracts (2A)
  → QueryWithRevenue (2B)
  → QueryWithOfferScheduling (3A)
  → QueryWithSync (3B)
  → QueryWithTransitions (4A/B)
  → QueryWithOptionalItems (5A)
  → QueryWithCostItems (5D) ← SCHEMA ROOT
```

Same pattern for mutations. Schema root is `QueryWithCostItems` / `MutationWithCostItems`.

---

## 5. Key Technical Notes for Troubleshooting

| Topic | Detail |
|---|---|
| **venv** | `.venv` at repo root, not in `backend/` |
| **Python** | 3.9 — use `Dict[str, Any]` not `dict[str, Any]` |
| **Dev server** | `./dev.sh` from project root |
| **Redis** | Connection pool in `rating_engine.py`, uses `hiredis` C parser |
| **Schema** | Large file (8492 lines) — uses class inheritance chain for GQL |
| **Models** | 1428 lines — all billing models in single file |
| **Invoice pricing** | Reads from `SubscriptionTariff` snapshot, NOT live offer |
| **Event emission** | Try/except wrapped — failures don't block mutations |
| **Deferred items** | All frontend UI for phases 4-5 is deferred |

---

*For full detail, see the companion files in `docs/`.*

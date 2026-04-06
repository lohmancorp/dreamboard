## Subscription & Billing To Do
To have a succesful billing system, the current software application has many of the pieces, but there are many rules and bits that remain unaccounted for.

### Offer to do
1) When I am making changes to an offer, the version number is not incrementing.
2) When I make changes to an offer, I should be presented with a chance to update existing subscriptions based on conditions and timing.
    2.A) Things to sync (one, some or all): product info, resources, amounts of resources, pricing.
    2.B) Timing (only one): immediately, on next month, on next billing period, on next renewal, or on a selected effective date.
3) Provide the ability to change an offer and set it available via an effective date.
4) The ability to change only the pricing and set it active via an effective date.
5) All such changes must be cataloged and visible in the UI via change log tab on offers that describes the change, when the change, and who made it.
6) I must be able to configure upgrade paths for offers.
7) I must be able to configure downgrade pathes for offers.
8) I must be able to configure independently if proration happens for an upgrade or downgrade.
9) I must be able to configure independently when the upgrade or downgrade happens.  Timing (only one): immediately, on next month, on next billing period, on next renewal, or on a selected effective date.
10) Optional additional configured items for an offer item must be configurable as persistent, one-time, or till consumed.
    10.A) Persistent = the resource is charged up front and the optional offer item upgrade remains on the subscription as an additional charge and available resource till cancelled or a different offer is purchased as part of an upgrade or downgrade of the offer.  Each additional billing period the optional resource is provided, charged for, and totals reset on billing period days.
    10.B) One-time = the resource is charged up front and provided and must be used in the next 30 days from purchase and then the additional resource is expired at the end of the 30 days with no additional charge.
    10.C) Till consumed =  the resource is charged up front and provided, and available till the full amount is consumed, without expiring on next billing period within 30 days.


### Subscription to do:
1) Once a subscription in generated, the pricing at the time of the subscription purchase must be stored in a tariff table in order to ensure that the billing occurs based on the pricing of the offer at the time.
2) See offer to do about types of changes and timing.  This will have an affect on the existing subscriptions.
3) All such changes must be cataloged and visible in the UI via change log tab on subscriptions in the customer and billing views that describes the change, when the change, and who made it.
4) A subscription must be considered a contract.  Each one commitment term purchased is a contract and this will be used to recognize revenue, to change pending to be recognized revenue, costs per period per subscription and eventually deferred revenue. 
5) If a subscription runs out of usage, the admin, isv, or customer must be provided one of the following configurable use-cases
    5.A) if an optional resource is configured, allow the user to buy the optional package according to the configuration I selected in 10 above.
    5.B) Offer a plan upgrade based on the configured offer upgrades.
    5.C) Return the user is out of usage and when it will reset.

### Rating & Usage Engine
1) Must be able to bill for a subscription with the included line items as a single subscription line item.  This is working now.
2) Must be able to draw down against included usage, optional usage (if subscribed to), and metered usage if configured on the offer. 
3) Usage and rating must be in real-time so the admin, isv, or isv's customer can see in real-time their usage and any associated costs based on non-included items.
4) Must be able to register cost/usage that is generic to all subscriptions and not subscription specifc usage and costs.  I will need a way to pre-configure these "Cost Items".

### Invoice to do:
1) Once an invoice is generated, it must become immutable for accounting and auditing purposes.
2) Change an invoice, it must be closed/cancelled and a new one issued with the corrections in place.  Please confirm on this point if this follows accounting and audit standards.

Please read the above items, review the code and produce a report that covers the following:
1) What I am missing.  The goal is to perform complex billing for ISVs and AI companies that need to understand did I cover everything needed by such companies.  
2) What is missing from the code today that would prevent me from doing the above.
3) Is there any additional steps required for financial and accounting compliance?
4) What would be the multi-phase plan to implement the above?
5) Do you have any questions?


Stripe vs. Internal Billing: The payment service currently has both a real Stripe integration and a dummy/fake service. Will production billing go through Stripe for payment processing while your platform handles the billing logic (invoice generation, proration, etc.)? Or do you plan to handle payment processing entirely in-house eventually?

Answer: I will handle payments through external integrations such as stripe or via bank transfer process.

Multi-Currency Scope: Is multi-currency billing a requirement for the initial launch, or can it be deferred? This significantly impacts the tariff table design.

Answer: Let's do it now.  I will always need to bring it back to a single currency that is configured as the main currency for an entity.  Entities are cloudblue (admin), Cloudblue's customer (isv), and the customer of our ISV customers (platform)

Tax Compliance Jurisdictions: Which jurisdictions do your ISV customers sell into? US-only, EU, or global? This determines whether you need basic tax tables or a full tax provider integration.

ANSWER: EU, USA, Canada.  I would like to add the other regions later.

Revenue Recognition Priority: Is ASC 606 / IFRS 15 compliance needed for the initial launch, or is it a Phase 2+ item? If ISVs are pre-revenue or early-stage, this can be deferred—but the data model should be designed to support it from day one.

ANSWER: Requirement now.  I need to be able to configure how things are recognized as well.

Self-Service vs. Admin-Only Changes: For upgrades/downgrades, should customers be able to self-serve from their portal (within ISV-configured paths), or are all transitions admin-initiated?

ANSWER: Both are needed.  I may help my client or my client may help themselves.  Primary goal is for self-service of everything, but with ability for me to help my customers.

Usage Enforcement Integration: How will you communicate entitlement decisions to the ISV's application? SDK/library, REST API, webhook, or all of the above?

ANSWER: I want to support all three scenarios.  But we must be able to rate real-time with a response of 50ms.  Upon submitting usage via API, the system should respond with usage remaining for item.

Subscription #5 (incomplete): Your requirement "5.A) if an optional resource is configured, allow the…" appears to be cut off. Can you complete this requirement?

Here is the complete item:
5) If a subscription runs out of usage, the admin, isv, or customer must be provided one of the following configurable use-cases
    5.A) if an optional resource is configured, allow the user to buy the optional package according to the configuration I selected in 10 above.
    5.B) Offer a plan upgrade based on the configured offer upgrades.
    5.C) Return the user is out of usage and when it will reset.


Contract Terms: Beyond commitment term (MTM, 1-year), do you need support for custom contract durations (e.g., 2-year, 3-year, quarter) or only the three currently defined?

ANSWER: I want to be able to configure more commitment terms and enforce what is allowed via https://admin.cloudblue.ai/settings/financeprofiles

Wallet Assignment: You mentioned wallets should be "assigned to one, some, or all subscriptions." Should wallet drawdown be automatic (deducted before card charge) or manual (customer chooses which payment source)?

ANSWER: Customer must fill wallet and charges will automatically be deducted from one wallet.  If more than one wallet is present, the customer may choose which wallet pays for which subscription.  We will have to build out the entire concept of wallets as well.

Event Sourcing vs. Change Tables: For the change log, do you prefer an event-sourcing pattern (immutable event stream that can rebuild state) or simpler before/after snapshot tables? Event sourcing is more powerful but significantly more complex.

ANSWER: Event sourcing as we will have to build this out for other features in the platform evenutally and to build that into an approval workflow.

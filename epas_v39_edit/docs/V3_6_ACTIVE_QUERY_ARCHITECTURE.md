# EPAS v3.6 Active Query Architecture

The application source now imports `database.production_queries` for active components. `database.queries` is a production-only compatibility shim with no demo/in-memory implementation.

Active workflow wrappers use v3.6 facade names. Historical SQL migrations remain only for database upgrade lineage; old authenticated application entry points are revoked in the v3.6 migration.

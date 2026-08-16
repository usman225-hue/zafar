# PSB EPAS v3.6.1 Frontend Upgrade

## Brand
- Pakistan Shipping Bureau logo added to `assets/psb_logo_master.png`
- Light and dark logo variants added
- PSB first-screen login experience added
- Authenticated PSB top bar added
- Sidebar brand updated to PSB
- EPAS is presented as the underlying system, not the organization name

## UX
- Role-native header and context bar
- PSB role pills for GM, DM, Engineer, Surveyor, Designer, Ship Management and stakeholder users
- Premium maritime palette: deep navy, teal, maritime green and controlled gold
- Improved cards, forms, file upload areas, buttons, navigation tabs and responsive behavior
- Reduced visual density and clearer next-action presentation
- Demo-mode banner removed from the production shell

## Login
The first screen now uses the supplied PSB logo, enhanced at high resolution, in a dedicated login hero next to the authenticated form.

## Role model
Internal:
- GM Classification
- Department Manager
- Authorized Engineer
- Authorized Surveyor

External stakeholders:
- Designer
- Ship Management
- Owner
- Shipyard

The visual treatment does not grant additional permissions; database RLS and workflow RPCs remain authoritative.

## Deployment
Use the existing production deployment instructions in `docs/V1_5_DEPLOYMENT_RUNBOOK.md` and the v3.6 release runbooks.

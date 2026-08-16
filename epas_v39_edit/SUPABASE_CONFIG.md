# EPAS v3.6 Supabase Configuration Guide

## Quick Setup

The EPAS application requires Supabase credentials to run in production mode.

### Step 1: Get Your Supabase Credentials

1. Go to your Supabase project: https://app.supabase.com
2. Navigate to **Settings → API**
3. Copy these values:
   - **Project URL** → `SUPABASE_URL`
   - **Anon (Public) Key** → `SUPABASE_ANON_KEY`

### Step 2: Configure Secrets

**Option A: Using `.streamlit/secrets.toml` (Recommended for development)**

Edit `/workspaces/ERPPSB/EPAS_v3_6/.streamlit/secrets.toml`:
```toml
SUPABASE_URL = "https://your-project-ref.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
```

Then rebuild and restart the container:
```bash
cd /workspaces/ERPPSB/EPAS_v3_6
docker stop epas-container && docker rm epas-container
docker build -t epas-app .
docker run -p 851:851 --name epas-container -e EPAS_REQUIRE_ANTIVIRUS=0 -d epas-app
```

**Option B: Using Environment Variables (For Docker)**

Start the container with environment variables:
```bash
docker run -p 851:851 \
  --name epas-container \
  -e EPAS_REQUIRE_ANTIVIRUS=0 \
  -e SUPABASE_URL="https://your-project-ref.supabase.co" \
  -e SUPABASE_ANON_KEY="your-anon-public-key" \
  -d epas-app
```

### Step 3: Verify Configuration

```bash
curl http://localhost:851
```

If the connection is successful, the app will load. If not, check logs:
```bash
docker logs epas-container
```

## Troubleshooting

- **"EPAS production configuration is unavailable"** → Missing or empty `SUPABASE_URL` or `SUPABASE_ANON_KEY`
- **"Invalid API key"** → Check that your keys are copied correctly from Supabase
- **"Connection refused"** → Ensure Supabase project is active and accessible

## Important Notes

- The **SUPABASE_ANON_KEY is not a secret** - it's a public key used for browser-based access
- Never expose the **service-role key** - that's private
- The application requires an active Supabase project with proper database schema

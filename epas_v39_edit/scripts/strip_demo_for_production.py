"""Create a production-only copy of the repository with demo runtime removed."""
from __future__ import annotations
import argparse, shutil
from pathlib import Path

DEMO_PATHS = [
    Path("config/demo_runtime.py"),
    Path("database/demo_queries_v40.py"),
    Path("database/seed_data.py"),
    Path("database/queries_legacy_archived.py"),
    Path("scripts/seed_demo_supabase.py"),
    Path("scripts/run_demo_8501.sh"),
    Path("scripts/promote_to_production.sh"),
    Path("scripts/strip_demo_for_production.py"),
    Path("README_DEMO_8501.md"),
    Path("README_PRODUCTION_SWITCH.md"),
    Path("DEMO_CREDENTIALS.md"),
    Path(".github_codespaces_8501.md"),
    Path(".env.demo"),
    Path(".devcontainer"),
    Path("docs/DEMO_MODE_GUIDE.md"),
    Path("README_V4_0_DEMO_PRODUCTION.md"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=".")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    src, out = Path(args.source).resolve(), Path(args.output).resolve()
    if out.exists(): shutil.rmtree(out)
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git"))
    for rel in DEMO_PATHS:
        p = out / rel
        if p.exists():
            if p.is_dir(): shutil.rmtree(p)
            else: p.unlink()
    (out / ".env").unlink(missing_ok=True)
    (out / ".env.demo").unlink(missing_ok=True)

    # Remove the demo binding block from the production query layer so the
    # promoted copy has one and only one runtime data source: Supabase.
    prod_queries = out / "database" / "production_queries.py"
    if prod_queries.exists():
        text = prod_queries.read_text(encoding="utf-8")
        marker = "\n# ---------------------------------------------------------------------------\n# Demo runtime override\n# ---------------------------------------------------------------------------"
        if marker in text:
            text = text.split(marker, 1)[0].rstrip() + "\n"
            prod_queries.write_text(text, encoding="utf-8")

    # Production copies should not include demo-only helper scripts.
    for rel in [Path("scripts/run_demo_8501.sh")]:
        (out / rel).unlink(missing_ok=True)

    (out / "PRODUCTION_MODE.txt").write_text(
        "EPAS_RUNTIME_MODE=production\nDemo runtime, credentials, seed data, demo adapter and Codespaces demo helpers removed by promotion script.\n",
        encoding="utf-8",
    )
    print(f"Production copy created at: {out}")

if __name__ == "__main__":
    main()

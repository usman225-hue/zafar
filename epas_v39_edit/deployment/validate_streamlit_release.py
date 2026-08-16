from pathlib import Path
import ast

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    ROOT / "app.py",
    ROOT / "requirements.txt",
    ROOT / "database/production_v3_2_final_performance_security_ux.sql",
    ROOT / "components/survey_lifecycle_v32.py",
    ROOT / "database/production_queries.py",
    ROOT / "tests/test_v32_final_hardening.py",
    ROOT / ".streamlit/secrets.toml.example",
]

for path in REQUIRED:
    if not path.exists():
        raise SystemExit(f"Missing release file: {path}")

for path in [ROOT / "app.py", ROOT / "components/survey_lifecycle_v32.py", ROOT / "database/production_queries.py"]:
    ast.parse(path.read_text(encoding="utf-8"))

req = (ROOT / "requirements.txt").read_text(encoding="utf-8")
if "streamlit" not in req.lower():
    raise SystemExit("Streamlit dependency is missing")

print("EPAS v3.2 Streamlit release file validation: PASS")

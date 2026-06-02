import os
from pathlib import Path
from dotenv import load_dotenv

# Read .env from Application Support so the bundled binary finds it regardless of CWD (D-13)
_app_support = Path.home() / "Library" / "Application Support" / "com.welisa.CallBridge"
load_dotenv(dotenv_path=_app_support / ".env")

# AssemblyAI
ASSEMBLYAI_API_KEY = os.getenv("ASSEMBLYAI_API_KEY")

# Google Gemini
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = "gemini-3-flash-preview"

# Salesforce
SF_USERNAME = os.getenv("SF_USERNAME")
SF_PASSWORD = os.getenv("SF_PASSWORD")
SF_SECURITY_TOKEN = os.getenv("SF_SECURITY_TOKEN")
SF_DOMAIN = os.getenv("SF_DOMAIN", "welisa")

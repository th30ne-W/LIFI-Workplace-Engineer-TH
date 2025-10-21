#!/usr/bin/env python3
"""
sync_transform_employees.py
---------------------------------
Fetches employees from the Random User HR API and transforms them
to the target Asset Management schema.

Features:
- Fetch from HR API with retry
- Transform + validate (UUID, email, required fields)
- Architecture per spec: asset_id, nested office_location, static fields
- Prettified JSON output with sync metadata
- Logging (file + console), summary of kept/skipped
- Bonus: --filter-state, days_since_hire, phone normalization, comparison with previous sync

Usage examples:
  python sync_transform_employees.py --results 10 --out asset_sync_output.json
  python sync_transform_employees.py --results 20 --filter-state "Texas"
  python sync_transform_employees.py --prev asset_sync_output.json
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import time
from datetime import datetime, timezone, date
from typing import Any, Dict, List, Optional, Tuple

import uuid

try:
    import requests
except ImportError:
    print("This script requires the 'requests' library. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)


# ------------------------------
# Config
# ------------------------------
HR_API_BASE = "https://randomuser.me/api/"
DEFAULT_RESULTS = 10
DEFAULT_OUT = "asset_sync_output.json"
DEFAULT_LOG = "asset_sync.log"
SOURCE_SYSTEM = "HR_API"


# ------------------------------
# Logging setup
# ------------------------------
def setup_logging(log_path: str, verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s | %(levelname)-8s | %(message)s"
    datefmt = "%Y-%m-%dT%H:%M:%SZ"
    logging.Formatter.converter = time.gmtime  # make times in UTC in logs

    handlers: List[logging.Handler] = []
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(level)
    fh.setFormatter(logging.Formatter(fmt=fmt, datefmt=datefmt))
    handlers.append(fh)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(level)
    ch.setFormatter(logging.Formatter(fmt=fmt, datefmt=datefmt))
    handlers.append(ch)

    logging.basicConfig(level=level, handlers=handlers)


# ------------------------------
# Utility helpers
# ------------------------------
def now_iso_utc() -> str:
    """UTC ISO-8601 with 'Z' suffix."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")


def unix_ts_now() -> int:
    """Unix timestamp (seconds)."""
    return int(datetime.now(timezone.utc).timestamp())


def validate_uuid(u: str) -> bool:
    try:
        uuid.UUID(u)
        return True
    except Exception:
        return False


EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def validate_email(email: str) -> bool:
    return bool(EMAIL_RE.match(email or ""))


PHONE_DIGITS_RE = re.compile(r"\D+")


def normalize_phone(phone: str) -> Optional[str]:
    """
    Normalize to (XXX) XXX-XXXX if 10 digits, else return original if non-empty.
    Return None if empty/invalid.
    """
    if not phone:
        return None
    digits = PHONE_DIGITS_RE.sub("", phone)
    if len(digits) == 10:
        return f"({digits[0:3]}) {digits[3:6]}-{digits[6:10]}"
    # Keep original if it at least contains digits; else None
    return phone if digits else None


def parse_yyyy_mm_dd_from_iso(dt_str: str) -> Optional[str]:
    """Extract YYYY-MM-DD from an ISO-like timestamp."""
    if not dt_str:
        return None
    try:
        # robust: use fromisoformat if possible (slightly lenient), else slice
        # RandomUser dates look like "2020-01-15T12:00:00.000Z"
        return dt_str[:10]
    except Exception:
        return None


def days_between_utc(start_date: str) -> Optional[int]:
    """Compute days from start_date (YYYY-MM-DD) to today (UTC)."""
    try:
        y, m, d = [int(x) for x in start_date.split("-")]
        start = date(y, m, d)
        today = datetime.now(timezone.utc).date()
        return (today - start).days
    except Exception:
        return None


def build_url(results: int) -> str:
    return f"{HR_API_BASE}?results={results}&nat=us"


# ------------------------------
# Fetch
# ------------------------------
def fetch_hr_data(results: int, retry: int = 1, timeout: int = 15) -> Dict[str, Any]:
    url = build_url(results)
    for attempt in range(retry + 1):
        try:
            logging.info(f"Fetching HR data: {url} (attempt {attempt+1}/{retry+1})")
            resp = requests.get(url, timeout=timeout)
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            logging.error(f"HR API request failed: {e}")
            if attempt < retry:
                backoff = 2 ** attempt
                logging.info(f"Retrying in {backoff}s...")
                time.sleep(backoff)
            else:
                raise
    # Should never hit here
    return {}


# ------------------------------
# Transform
# ------------------------------
def transform_record(
    rec: Dict[str, Any],
    now_ts: int,
    *,
    state_filter: Optional[str] = None,
    include_days_since_hire: bool = True,
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """
    Transform a single HR record into the Asset schema.
    Returns (transformed_record, skip_reason).
    If skip_reason is not None, the record is invalid and skipped.
    """

    # Safely pluck fields
    login = rec.get("login") or {}
    loc = rec.get("location") or {}
    name = rec.get("name") or {}
    reg = rec.get("registered") or {}

    employee_id = login.get("uuid") or ""
    first = (name.get("first") or "").strip()
    last = (name.get("last") or "").strip()
    full_name = f"{first} {last}".strip()
    email = rec.get("email") or ""
    phone = rec.get("phone") or ""
    city = (loc.get("city") or "").strip()
    state = (loc.get("state") or "").strip()
    country = (loc.get("country") or "").strip()
    hire_date = parse_yyyy_mm_dd_from_iso(reg.get("date") or "")

    # Optional filter by state (bonus)
    if state_filter and state.casefold() != state_filter.casefold():
        return None, f"filtered_out_state:{state}"

    # Required validations
    if not employee_id:
        return None, "missing_uuid"
    if not validate_uuid(employee_id):
        return None, f"invalid_uuid:{employee_id}"
    if not first or not last:
        return None, "missing_name"
    if not email or not validate_email(email):
        return None, f"invalid_email:{email}"
    if not city or not state or not country:
        return None, "missing_location"
    if not hire_date:
        return None, "invalid_hire_date"

    # Asset/id generation per spec: ASSET-{uuid[:8]}-{unix_timestamp}
    asset_id = f"ASSET-{employee_id[:8]}-{now_ts}"

    # Phone normalization (bonus – best effort)
    contact_number = normalize_phone(phone) or phone or ""

    # Base record
    out = {
        "asset_id": asset_id,
        "employee_full_name": full_name,
        "employee_id": employee_id,
        "work_email": email,
        "contact_number": contact_number,
        "office_location": {
            "city": city,
            "state": state,
            "country": country,
        },
        "employee_status": "active",
        "hire_date": hire_date,
        "department": "unassigned",
    }

    # Bonus: days_since_hire
    if include_days_since_hire:
        dsh = days_between_utc(hire_date)
        if dsh is not None and dsh >= 0:
            out["days_since_hire"] = dsh

    return out, None


# ------------------------------
# Comparison with previous sync (bonus)
# ------------------------------
def compare_with_previous(
    current: List[Dict[str, Any]],
    prev_path: str,
) -> Tuple[int, int, int]:
    """Return (added, removed, unchanged) counts by employee_id."""
    try:
        with open(prev_path, "r", encoding="utf-8") as f:
            prev = json.load(f)
        prev_ids = {e.get("employee_id") for e in (prev.get("employees") or []) if e.get("employee_id")}
        curr_ids = {e.get("employee_id") for e in (current or []) if e.get("employee_id")}
        added = len(curr_ids - prev_ids)
        removed = len(prev_ids - curr_ids)
        unchanged = len(curr_ids & prev_ids)
        return added, removed, unchanged
    except FileNotFoundError:
        logging.warning(f"Previous sync file not found: {prev_path}")
        return 0, 0, 0
    except Exception as e:
        logging.error(f"Failed to compare with previous sync: {e}")
        return 0, 0, 0


# ------------------------------
# Main
# ------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Sync + transform HR employees to Asset schema.")
    parser.add_argument("--results", type=int, default=DEFAULT_RESULTS, help="Number of employees to fetch (default: 10)")
    parser.add_argument("--out", default=DEFAULT_OUT, help="Output JSON file path")
    parser.add_argument("--filter-state", dest="filter_state", default=None, help="Only include employees from this state (case-insensitive)")
    parser.add_argument("--prev", dest="prev", default=None, help="Path to previous output for comparison (bonus)")
    parser.add_argument("--log", dest="log_path", default=DEFAULT_LOG, help="Log file path")
    parser.add_argument("--verbose", action="store_true", help="Verbose logging")
    args = parser.parse_args()

    setup_logging(args.log_path, verbose=args.verbose)

    # Fetch
    try:
        payload = fetch_hr_data(args.results, retry=1)
    except Exception as e:
        logging.error(f"Aborting: could not fetch HR data. {e}")
        return 2

    raw_results = (payload or {}).get("results") or []
    logging.info(f"Fetched {len(raw_results)} records from HR API.")

    # Transform
    now_iso = now_iso_utc()
    now_ts = unix_ts_now()

    employees: List[Dict[str, Any]] = []
    skipped: List[str] = []

    for idx, rec in enumerate(raw_results, start=1):
        transformed, reason = transform_record(
            rec,
            now_ts,
            state_filter=args.filter_state,
            include_days_since_hire=True,
        )
        if transformed:
            employees.append(transformed)
        else:
            skipped.append(reason or "unknown_reason")
            logging.warning(f"Skipping record {idx}: {reason}")

    # Comparison (bonus)
    if args.prev:
        added, removed, unchanged = compare_with_previous(employees, args.prev)
        logging.info(f"Comparison vs previous: added={added}, removed={removed}, unchanged={unchanged}")

    # Build output
    out = {
        "sync_metadata": {
            "sync_timestamp": now_iso,
            "source_system": SOURCE_SYSTEM,
            "record_count": len(employees),
        },
        "employees": employees,
    }

    # Write output
    try:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
        logging.info(f"Wrote transformed output to: {args.out}")
    except Exception as e:
        logging.error(f"Failed to write output file: {e}")
        return 3

    # Summary
    logging.info("----- Summary -----")
    logging.info(f"Requested: {args.results}")
    logging.info(f"Transformed (kept): {len(employees)}")
    logging.info(f"Skipped: {len(skipped)}")
    if skipped:
        # brief breakdown of skip reasons
        from collections import Counter
        counts = Counter(skipped)
        for reason, count in counts.items():
            logging.info(f"  - {reason}: {count}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

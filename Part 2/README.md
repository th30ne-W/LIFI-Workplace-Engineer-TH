# Part 2: API Integration & Data Transformation

## Objective
Build a synchronization tool that fetches employee data from the HR API and transforms it to match the Asset Management system's schema (with different field names and structure).

## Your Solution

### Script Name
sync_transform_employees.py

### Language Used
Python (3.8 or newer)

### How to Run


```bash
# Install required dependency
pip install requests

# Basic usage (fetches 10 users and saves to asset_sync_output.json)
python sync_transform_employees.py

# Specify number of results
python sync_transform_employees.py --results 20

# Filter by state (bonus feature)
python sync_transform_employees.py --filter-state "Texas"

# Compare with previous sync (bonus feature)
python sync_transform_employees.py --prev asset_sync_output.json

# Verbose logging
python sync_transform_employees.py --verbose

# Custom output and log paths
python sync_transform_employees.py --out output.json --log run.log
```

### API Used
- **Source Endpoint:** https://randomuser.me/api/?results=10&nat=us
- **Method:** GET
- **Destination:** Local JSON file (asset_sync_output.json) matching the Asset Management schema

### Data Transformation Implemented

#### Field Mappings
- [x] `login.uuid` → `employee_id`
- [x] `login.uuid` + timestamp → `asset_id` (format: ASSET-{uuid}-{timestamp})
- [x] `name.first` + `name.last` → `employee_full_name`
- [x] `email` → `work_email`
- [x] `phone` → `contact_number`
- [x] `location.*` → `office_location` (nested object)
- [x] `registered.date` → `hire_date` (date only)
- [x] Static values: `employee_status`, `department`
- [x] Metadata: `sync_timestamp`, `source_system`, `record_count`

### Features Implemented

- [x] Fetches employee data from HR API
- [x] Transforms nested objects (name, location)
- [x] Generates unique asset tags
- [x] Extracts dates from timestamps
- [x] Creates sync metadata
- [x] Validates data (emails, required fields)
- [x] Outputs to JSON file with proper structure
- [x] Skips invalid records with logging
- [x] Error handling for API failures
- [x] Logs skipped/failed records
- [x] Summary of successful/failed transformations

### Bonus Features (if implemented)

- [x] --filter-state option to limit results by U.S. state
- [x] Calculates days_since_hire based on hire_date
- [x] Phone number format normalization ((XXX) XXX-XXXX)
- [x] Comparison with previous sync (--prev flag) to detect added/removed/unchanged employees

### Output Format

The script generates `asset_sync_output.json` with this structure:

```json
{
  "sync_metadata": {
    "sync_timestamp": "ISO-8601 timestamp",
    "source_system": "HR_API",
    "record_count": 10
  },
  "employees": [
    {
      "asset_id": "ASSET-{uuid-prefix}-{timestamp}",
      "employee_full_name": "First Last",
      "employee_id": "full-uuid",
      "work_email": "email@example.com",
      "contact_number": "(555) 123-4567",
      "office_location": {
        "city": "City",
        "state": "State",
        "country": "Country"
      },
      "employee_status": "active",
      "hire_date": "YYYY-MM-DD",
      "department": "unassigned",
      "days_since_hire": "current_utc_date - registered.date"
    }
  ]
}
```

### Testing
- ✅ Ran multiple fetches (--results 2, --results 20) to verify scaling.
- ✅ Tested filtering behavior (--filter-state) with multiple states to confirm correct inclusion/exclusion.
- ✅ Confirmed summary counts and log output match transformed record counts.
- ✅ Validated JSON output structure and schema against spec.
- ✅ Used --prev to compare two outputs and verified correct added/removed counts.
- ✅ Tested --out and --log parameters and confirmed that custom output and log files are correctly created

### Data Validation Rules
- login.uuid must be valid UUIDv4.
- name.first and name.last must be present.
- email must contain @ and basic domain structure.
- location.city, location.state, and location.country required.
- registered.date must parse to YYYY-MM-DD.
- Records failing validation are skipped and logged.

### Assumptions
- API response structure follows RandomUser.me’s standard format.
- Internet connectivity is available for API fetch.
- Output directory is writable.
- Timezone is UTC for consistency of timestamps.
- Previous sync file (if used) has valid JSON structure.

### Dependencies
- requests (for API calls)
- json, datetime, uuid, re, argparse, logging (standard library)

### Known Limitations

- Basic email/phone validation (not full regex compliance).
- No automatic retries beyond a single backoff attempt.
- Previous sync comparison based solely on employee_id.
- Does not upload to real Asset Management API — outputs to local JSON only.

### Example Transformations

#### Example 1:

python sync_transform_employees.py --results 2
2025-10-21T10:10:06Z | INFO     | Fetching HR data: https://randomuser.me/api/?results=2&nat=us (attempt 1/2)
2025-10-21T10:10:07Z | INFO     | Fetched 2 records from HR API.
2025-10-21T10:10:07Z | INFO     | Wrote transformed output to: asset_sync_output.json
2025-10-21T10:10:07Z | INFO     | ----- Summary -----
2025-10-21T10:10:07Z | INFO     | Requested: 2
2025-10-21T10:10:07Z | INFO     | Transformed (kept): 2
2025-10-21T10:10:07Z | INFO     | Skipped: 0

```json
{
  "sync_metadata": {
    "sync_timestamp": "2025-10-21T10:10:07.175478Z",
    "source_system": "HR_API",
    "record_count": 2
  },
  "employees": [
    {
      "asset_id": "ASSET-16fb937e-1761041407",
      "employee_full_name": "Brian Hernandez",
      "employee_id": "16fb937e-c6b6-4b2a-bf0d-a0d285d03dc2",
      "work_email": "brian.hernandez@example.com",
      "contact_number": "(638) 228-8134",
      "office_location": {
        "city": "Cupertino",
        "state": "Mississippi",
        "country": "United States"
      },
      "employee_status": "active",
      "hire_date": "2019-06-13",
      "department": "unassigned",
      "days_since_hire": 2322
    },
    {
      "asset_id": "ASSET-5ba3eba3-1761041407",
      "employee_full_name": "Cassandra Stanley",
      "employee_id": "5ba3eba3-cf11-46f5-9584-1a2d2cdb655c",
      "work_email": "cassandra.stanley@example.com",
      "contact_number": "(911) 759-7603",
      "office_location": {
        "city": "Green Bay",
        "state": "Kentucky",
        "country": "United States"
      },
      "employee_status": "active",
      "hire_date": "2015-01-31",
      "department": "unassigned",
      "days_since_hire": 3916
    }
  ]
}
```

#### Example 2

python sync_transform_employees.py --results 30 --filter-state "New York" --verbose
2025-10-21T10:41:27Z | INFO     | Fetching HR data: https://randomuser.me/api/?results=30&nat=us (attempt 1/2)
2025-10-21T10:41:27Z | DEBUG    | Starting new HTTPS connection (1): randomuser.me:443
2025-10-21T10:41:27Z | DEBUG    | https://randomuser.me:443 "GET /api/?results=30&nat=us HTTP/1.1" 200 None
2025-10-21T10:41:27Z | INFO     | Fetched 30 records from HR API.
2025-10-21T10:41:27Z | WARNING  | Skipping record 1: filtered_out_state:California
2025-10-21T10:41:27Z | WARNING  | Skipping record 2: filtered_out_state:Iowa
2025-10-21T10:41:27Z | WARNING  | Skipping record 3: filtered_out_state:Maine
2025-10-21T10:41:27Z | WARNING  | Skipping record 4: filtered_out_state:Washington
2025-10-21T10:41:27Z | WARNING  | Skipping record 5: filtered_out_state:South Carolina
2025-10-21T10:41:27Z | WARNING  | Skipping record 6: filtered_out_state:New Jersey
2025-10-21T10:41:27Z | WARNING  | Skipping record 7: filtered_out_state:New Jersey
2025-10-21T10:41:27Z | WARNING  | Skipping record 8: filtered_out_state:New Jersey
2025-10-21T10:41:27Z | WARNING  | Skipping record 10: filtered_out_state:Louisiana
2025-10-21T10:41:27Z | WARNING  | Skipping record 11: filtered_out_state:Kansas
2025-10-21T10:41:27Z | WARNING  | Skipping record 12: filtered_out_state:Mississippi
2025-10-21T10:41:27Z | WARNING  | Skipping record 13: filtered_out_state:Connecticut
2025-10-21T10:41:27Z | WARNING  | Skipping record 14: filtered_out_state:South Dakota
2025-10-21T10:41:27Z | WARNING  | Skipping record 15: filtered_out_state:Kansas
2025-10-21T10:41:27Z | WARNING  | Skipping record 16: filtered_out_state:Kentucky
2025-10-21T10:41:27Z | WARNING  | Skipping record 17: filtered_out_state:Massachusetts
2025-10-21T10:41:27Z | WARNING  | Skipping record 18: filtered_out_state:Florida
2025-10-21T10:41:27Z | WARNING  | Skipping record 19: filtered_out_state:Kansas
2025-10-21T10:41:27Z | WARNING  | Skipping record 20: filtered_out_state:Ohio
2025-10-21T10:41:27Z | WARNING  | Skipping record 21: filtered_out_state:Kansas
2025-10-21T10:41:27Z | WARNING  | Skipping record 22: filtered_out_state:Nevada
2025-10-21T10:41:27Z | WARNING  | Skipping record 23: filtered_out_state:Delaware
2025-10-21T10:41:27Z | WARNING  | Skipping record 24: filtered_out_state:Hawaii
2025-10-21T10:41:27Z | WARNING  | Skipping record 25: filtered_out_state:Missouri
2025-10-21T10:41:27Z | WARNING  | Skipping record 26: filtered_out_state:New Mexico
2025-10-21T10:41:27Z | WARNING  | Skipping record 27: filtered_out_state:Kentucky
2025-10-21T10:41:27Z | WARNING  | Skipping record 28: filtered_out_state:North Dakota
2025-10-21T10:41:27Z | WARNING  | Skipping record 30: filtered_out_state:Mississippi
2025-10-21T10:41:27Z | INFO     | Wrote transformed output to: asset_sync_output.json
2025-10-21T10:41:27Z | INFO     | ----- Summary -----
2025-10-21T10:41:27Z | INFO     | Requested: 30
2025-10-21T10:41:27Z | INFO     | Transformed (kept): 2
2025-10-21T10:41:27Z | INFO     | Skipped: 28
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:California: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Iowa: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Maine: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Washington: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:South Carolina: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:New Jersey: 3
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Louisiana: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Kansas: 4
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Mississippi: 2
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Connecticut: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:South Dakota: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Kentucky: 2
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Massachusetts: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Florida: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Ohio: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Nevada: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Delaware: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Hawaii: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:Missouri: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:New Mexico: 1
2025-10-21T10:41:27Z | INFO     |   - filtered_out_state:North Dakota: 1

```json
{
  "sync_metadata": {
    "sync_timestamp": "2025-10-21T10:41:27Z",
    "source_system": "HR_API",
    "record_count": 2
  },
  "employees": [
    {
      "asset_id": "ASSET-df3ef242-1761043287",
      "employee_full_name": "Alvin Peters",
      "employee_id": "df3ef242-bd14-4aa2-8a9a-b940968159d0",
      "work_email": "alvin.peters@example.com",
      "contact_number": "(564) 707-1697",
      "office_location": {
        "city": "Green Bay",
        "state": "New York",
        "country": "United States"
      },
      "employee_status": "active",
      "hire_date": "2014-09-07",
      "department": "unassigned",
      "days_since_hire": 4062
    },
    {
      "asset_id": "ASSET-9ae19ea1-1761043287",
      "employee_full_name": "Javier Gilbert",
      "employee_id": "9ae19ea1-ace9-4687-91e0-f10859a9e2a5",
      "work_email": "javier.gilbert@example.com",
      "contact_number": "(636) 835-4962",
      "office_location": {
        "city": "Topeka",
        "state": "New York",
        "country": "United States"
      },
      "employee_status": "active",
      "hire_date": "2008-07-25",
      "department": "unassigned",
      "days_since_hire": 6297
    }
  ]
}
```

### You can find all generated files in the Part 2 root folder:

- asset_sync_output.json — main output file
- asset_sync.log — main log file
- out.json — output from custom --out test
- run.log — log from custom --log test


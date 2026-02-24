#!/bin/bash
# generate-test-data.sh — Generate curated CSV test data for Gridka screenshots.
#
# Usage:
#   ./generate-test-data.sh [output_directory]
#
# Generates several small, hand-crafted CSVs (good looking in screenshots)
# and one large generated CSV for the "big file" demo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${1:-${SCRIPT_DIR}/data}"

echo "==> Generating screenshot test data in: ${DATA_DIR}"
mkdir -p "$DATA_DIR"

# ═══════════════════════════════════════════════════════════════════════════
#  1. sales_data.csv — Business/company data (main "loaded CSV" screenshot)
# ═══════════════════════════════════════════════════════════════════════════

cat > "${DATA_DIR}/sales_data.csv" << 'CSV'
Company,Revenue ($M),Employees,Founded,Industry,Country,HQ City,Public,Growth (%),Website
Nexora Technologies,4280,12400,2003,Cloud Computing,United States,San Francisco,true,23.5,https://nexora.tech
Helvion Pharma,8920,34200,1987,Pharmaceuticals,Switzerland,Basel,true,8.2,https://helvion.ch
Kaiyo Robotics,1560,4800,2015,Robotics,Japan,Tokyo,false,41.7,https://kaiyo.jp
Polaris Financial,12400,28900,1962,Financial Services,United Kingdom,London,true,5.1,https://polarisfin.co.uk
Verdant Agriculture,890,6200,2010,AgTech,Netherlands,Amsterdam,false,18.3,https://verdantagri.nl
Solara Energy,3200,9800,2008,Renewable Energy,Germany,Munich,true,29.4,https://solaraenergy.de
Crestline Media,2100,7500,1995,Digital Media,United States,New York,true,12.8,https://crestline.media
Meridian Aerospace,18700,52000,1971,Aerospace,France,Toulouse,true,6.9,https://meridian-aero.fr
Titanforge Manufacturing,5600,21000,1989,Industrial,South Korea,Seoul,true,10.2,https://titanforge.kr
Luminos Health,1340,3900,2012,Digital Health,Canada,Toronto,false,35.6,https://luminoshealth.ca
Orion Logistics,7800,45000,1978,Logistics,United States,Memphis,true,14.1,https://orionlogistics.com
ZenithWave Electronics,9400,31000,1992,Consumer Electronics,Taiwan,Taipei,true,7.8,https://zenithwave.tw
Aquila Insurance,6200,18500,1955,Insurance,Germany,Frankfurt,true,3.4,https://aquila-ins.de
Boreal Mining,4100,15000,1968,Mining,Australia,Perth,true,11.3,https://borealmining.au
CodeVault Security,780,2100,2017,Cybersecurity,Israel,Tel Aviv,false,52.1,https://codevault.io
Cascade Retail,11300,67000,1984,Retail,United States,Seattle,true,4.7,https://cascaderetail.com
NovaBridge Telecom,8100,24000,1996,Telecommunications,India,Mumbai,true,16.5,https://novabridge.in
Prisma Chemicals,3700,11200,1975,Chemicals,Brazil,Sao Paulo,true,8.9,https://prismachemicals.br
Alpine Precision,1980,5400,2006,Medical Devices,Austria,Vienna,false,22.3,https://alpineprecision.at
Stratos Aviation,2800,8200,2001,Aviation,Singapore,Singapore,false,19.7,https://stratosaviation.sg
Dynamo Sports,4500,13600,1999,Sports & Fitness,United States,Portland,true,13.4,https://dynamosports.com
Fjordline Shipping,6700,19000,1965,Shipping,Norway,Oslo,true,5.8,https://fjordline-ship.no
Kantar Data Systems,2300,6800,2011,Data Analytics,United States,Austin,false,27.9,https://kantardata.com
Oakhaven Biotech,920,2800,2016,Biotechnology,United States,Boston,false,44.2,https://oakhavenbio.com
TerraNova Construction,5100,32000,1982,Construction,Spain,Madrid,true,7.1,https://terranova-const.es
Wavecrest Semiconductors,6800,22000,2000,Semiconductors,South Korea,Suwon,true,18.8,https://wavecrest-semi.kr
Pinnacle Hotels,3400,41000,1973,Hospitality,United Arab Emirates,Dubai,true,9.5,https://pinnaclehotels.ae
Aether Games,1200,3200,2014,Gaming,Sweden,Stockholm,false,38.4,https://aether.games
Redwood Analytics,1650,4100,2013,Business Intelligence,United States,Denver,false,31.2,https://redwoodanalytics.com
Pacifica Foods,7200,53000,1969,Food & Beverage,Mexico,Mexico City,true,6.3,https://pacificafoods.mx
Cirrus Fintech,2900,7200,2009,Fintech,United Kingdom,London,false,25.7,https://cirrus.finance
Helios Solar,1800,5100,2011,Solar Energy,Spain,Barcelona,false,33.9,https://heliossolar.es
Ironclad Defense,14200,38000,1958,Defense,United States,Arlington,true,4.2,https://ironcladdefense.com
Mapleleaf Ventures,520,1400,2019,Venture Capital,Canada,Vancouver,false,67.8,https://mapleleafvc.ca
Quantum Materials,3100,9600,2005,Advanced Materials,Germany,Dresden,false,20.1,https://quantummaterials.de
Sapphire Education,680,8900,2007,EdTech,India,Bangalore,false,28.6,https://sapphire-ed.in
TerraVerde Wines,450,2200,1991,Wine & Spirits,Italy,Florence,false,7.4,https://terraverde.wine
Northstar Payments,5800,16000,1998,Payment Processing,United States,Atlanta,true,15.3,https://northstarpay.com
Elevate Consulting,1100,6500,2002,Management Consulting,United Kingdom,Edinburgh,false,11.9,https://elevate-consult.co.uk
Horizon Shipping,8400,27000,1972,Maritime Transport,Greece,Athens,true,5.5,https://horizonship.gr
CSV

echo "    Created: sales_data.csv (40 rows)"

# ═══════════════════════════════════════════════════════════════════════════
#  2. api_logs.csv — API request/response logs with JSON bodies
#     (for "Detail Pane" screenshot — JSON column content)
# ═══════════════════════════════════════════════════════════════════════════

cat > "${DATA_DIR}/api_logs.csv" << 'CSV'
Timestamp,Endpoint,Method,Status,Latency (ms),Response Body,Client IP,User Agent
2025-02-24 09:12:03,/api/v2/users,GET,200,45,"{""users"": [{""id"": 1, ""name"": ""Alice Chen"", ""email"": ""alice@nexora.tech"", ""role"": ""admin"", ""last_login"": ""2025-02-24T08:45:00Z""}, {""id"": 2, ""name"": ""Bob Martinez"", ""email"": ""bob@nexora.tech"", ""role"": ""editor"", ""last_login"": ""2025-02-23T17:30:00Z""}], ""total"": 2, ""page"": 1, ""per_page"": 20}",192.168.1.45,Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15
2025-02-24 09:12:07,/api/v2/users/1/profile,GET,200,32,"{""id"": 1, ""name"": ""Alice Chen"", ""avatar"": ""https://cdn.nexora.tech/avatars/alice.jpg"", ""department"": ""Engineering"", ""title"": ""Senior Staff Engineer"", ""joined"": ""2019-03-15"", ""skills"": [""Go"", ""Rust"", ""Kubernetes"", ""DuckDB""], ""projects"": 12}",192.168.1.45,Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15
2025-02-24 09:12:15,/api/v2/analytics/dashboard,POST,200,187,"{""period"": ""2025-02"", ""metrics"": {""active_users"": 14523, ""new_signups"": 892, ""revenue"": 245000.50, ""churn_rate"": 0.023, ""avg_session_minutes"": 18.7}, ""charts"": {""daily_active"": [12100, 13200, 14523], ""conversion_funnel"": {""visited"": 50000, ""signed_up"": 892, ""activated"": 445, ""subscribed"": 178}}}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:12:18,/api/v2/products,GET,200,78,"{""products"": [{""sku"": ""PRD-001"", ""name"": ""CloudSync Pro"", ""price"": 29.99, ""currency"": ""USD""}, {""sku"": ""PRD-002"", ""name"": ""DataVault Enterprise"", ""price"": 149.99, ""currency"": ""USD""}, {""sku"": ""PRD-003"", ""name"": ""SecureAuth Plus"", ""price"": 79.99, ""currency"": ""USD""}], ""total"": 3}",172.16.0.88,python-requests/2.31.0
2025-02-24 09:12:22,/api/v2/auth/login,POST,200,156,"{""token"": ""eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzQyIiwiaWF0IjoxNzA4NzY0NzQyfQ"", ""expires_in"": 3600, ""refresh_token"": ""rt_a8f3b2c1d4e5"", ""user"": {""id"": 42, ""name"": ""Carol Park"", ""role"": ""viewer""}}",203.0.113.42,okhttp/4.12.0
2025-02-24 09:12:25,/api/v2/users/999,GET,404,12,"{""error"": {""code"": ""NOT_FOUND"", ""message"": ""User with ID 999 does not exist"", ""request_id"": ""req_7f8a9b2c""}}",192.168.1.45,Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15
2025-02-24 09:12:31,/api/v2/search,POST,200,234,"{""query"": ""kubernetes deployment"", ""results"": [{""id"": ""doc-127"", ""title"": ""Getting Started with Kubernetes"", ""score"": 0.95, ""snippet"": ""Learn how to deploy your first application...""}, {""id"": ""doc-203"", ""title"": ""Advanced K8s Patterns"", ""score"": 0.87, ""snippet"": ""Production-ready deployment strategies...""}], ""total_results"": 47, ""took_ms"": 89}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:12:34,/api/v2/webhooks,POST,201,67,"{""id"": ""wh_3f2a1b"", ""url"": ""https://hooks.slack.com/services/T00/B00/xxx"", ""events"": [""user.created"", ""order.completed"", ""payment.failed""], ""active"": true, ""created_at"": ""2025-02-24T09:12:34Z""}",172.16.0.88,python-requests/2.31.0
2025-02-24 09:12:38,/api/v2/billing/invoices,GET,200,98,"{""invoices"": [{""id"": ""INV-2025-0047"", ""amount"": 2499.00, ""currency"": ""USD"", ""status"": ""paid"", ""issued"": ""2025-02-01"", ""paid_at"": ""2025-02-03""}, {""id"": ""INV-2025-0048"", ""amount"": 1299.50, ""currency"": ""USD"", ""status"": ""pending"", ""issued"": ""2025-02-15"", ""due"": ""2025-03-15""}], ""total_outstanding"": 1299.50}",203.0.113.42,okhttp/4.12.0
2025-02-24 09:12:41,/api/v2/auth/refresh,POST,401,8,"{""error"": {""code"": ""TOKEN_EXPIRED"", ""message"": ""Refresh token has expired. Please log in again."", ""request_id"": ""req_c4d5e6f7""}}",192.168.1.102,axios/1.6.7
2025-02-24 09:12:45,/api/v2/reports/generate,POST,202,45,"{""job_id"": ""job_9a8b7c6d"", ""status"": ""queued"", ""estimated_completion"": ""2025-02-24T09:15:00Z"", ""report_type"": ""monthly_summary"", ""parameters"": {""month"": ""2025-01"", ""include_charts"": true, ""format"": ""pdf""}}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:12:48,/api/v2/notifications,GET,200,55,"{""notifications"": [{""id"": ""n_001"", ""type"": ""info"", ""message"": ""System maintenance scheduled for Feb 28"", ""read"": false}, {""id"": ""n_002"", ""type"": ""success"", ""message"": ""Your export is ready for download"", ""read"": true}, {""id"": ""n_003"", ""type"": ""warning"", ""message"": ""API rate limit at 80% capacity"", ""read"": false}], ""unread_count"": 2}",172.16.0.88,python-requests/2.31.0
2025-02-24 09:12:52,/api/v2/files/upload,POST,200,1245,"{""file_id"": ""f_abc123"", ""filename"": ""Q4-2024-report.pdf"", ""size_bytes"": 2457600, ""mime_type"": ""application/pdf"", ""checksum"": ""sha256:a1b2c3d4e5f6"", ""storage_url"": ""s3://nexora-files/uploads/2025/02/f_abc123.pdf""}",192.168.1.45,Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15
2025-02-24 09:12:55,/api/v2/config,GET,200,15,"{""features"": {""dark_mode"": true, ""beta_search"": false, ""ai_assist"": true, ""export_limit"": 10000}, ""version"": ""2.14.3"", ""environment"": ""production"", ""region"": ""us-west-2""}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:12:58,/api/v2/users,POST,422,23,"{""error"": {""code"": ""VALIDATION_ERROR"", ""message"": ""Request validation failed"", ""details"": [{""field"": ""email"", ""message"": ""Invalid email format""}, {""field"": ""password"", ""message"": ""Must be at least 12 characters""}], ""request_id"": ""req_d8e9f0a1""}}",203.0.113.42,okhttp/4.12.0
2025-02-24 09:13:02,/api/v2/audit/events,GET,200,145,"{""events"": [{""timestamp"": ""2025-02-24T09:12:22Z"", ""actor"": ""user_42"", ""action"": ""login"", ""ip"": ""203.0.113.42"", ""result"": ""success""}, {""timestamp"": ""2025-02-24T09:11:55Z"", ""actor"": ""user_17"", ""action"": ""password_change"", ""ip"": ""192.168.1.102"", ""result"": ""success""}, {""timestamp"": ""2025-02-24T09:10:30Z"", ""actor"": ""system"", ""action"": ""rate_limit_warning"", ""ip"": ""10.0.0.1"", ""result"": ""triggered""}], ""total"": 156, ""page"": 1}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:13:05,/api/v2/integrations/slack,POST,200,89,"{""integration_id"": ""int_slack_001"", ""workspace"": ""Nexora Engineering"", ""channel"": ""#deployments"", ""status"": ""connected"", ""permissions"": [""chat:write"", ""channels:read"", ""reactions:write""]}",172.16.0.88,python-requests/2.31.0
2025-02-24 09:13:10,/api/v2/ml/predictions,POST,200,567,"{""model"": ""churn-predictor-v3"", ""predictions"": [{""user_id"": 1042, ""churn_probability"": 0.12, ""risk_level"": ""low""}, {""user_id"": 1087, ""churn_probability"": 0.78, ""risk_level"": ""high""}, {""user_id"": 1123, ""churn_probability"": 0.45, ""risk_level"": ""medium""}], ""model_version"": ""3.2.1"", ""inference_time_ms"": 234}",10.0.0.12,PostmanRuntime/7.36.1
2025-02-24 09:13:15,/api/v2/health,GET,200,3,"{""status"": ""healthy"", ""uptime_seconds"": 1728345, ""database"": ""connected"", ""cache"": ""connected"", ""queue"": ""connected"", ""version"": ""2.14.3""}",10.0.0.1,kube-probe/1.28
2025-02-24 09:13:18,/api/v2/exports,POST,500,2034,"{""error"": {""code"": ""INTERNAL_ERROR"", ""message"": ""Export generation failed: connection pool exhausted"", ""request_id"": ""req_e1f2a3b4"", ""retry_after"": 30}}",192.168.1.45,Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3) AppleWebKit/605.1.15
CSV

echo "    Created: api_logs.csv (20 rows)"

# ═══════════════════════════════════════════════════════════════════════════
#  3. world_cities.csv — Major cities (good for filtering/sorting demos)
# ═══════════════════════════════════════════════════════════════════════════

cat > "${DATA_DIR}/world_cities.csv" << 'CSV'
City,Country,Population,Latitude,Longitude,Continent,Timezone,Elevation (m),Founded,Language
Tokyo,Japan,13960000,35.6762,139.6503,Asia,UTC+9,40,1457,Japanese
Delhi,India,32940000,28.7041,77.1025,Asia,UTC+5:30,216,736,Hindi
Shanghai,China,28520000,31.2304,121.4737,Asia,UTC+8,4,991,Mandarin
Sao Paulo,Brazil,22430000,-23.5505,-46.6333,South America,UTC-3,760,1554,Portuguese
Mexico City,Mexico,21920000,19.4326,-99.1332,North America,UTC-6,2240,1325,Spanish
Cairo,Egypt,22180000,30.0444,31.2357,Africa,UTC+2,75,969,Arabic
Mumbai,India,21670000,19.0760,72.8777,Asia,UTC+5:30,14,1507,Marathi
Beijing,China,21540000,39.9042,116.4074,Asia,UTC+8,43,1045,Mandarin
Dhaka,Bangladesh,23210000,23.8103,90.4125,Asia,UTC+6,9,1608,Bengali
Osaka,Japan,19060000,34.6937,135.5023,Asia,UTC+9,12,645,Japanese
New York,United States,18870000,40.7128,-74.0060,North America,UTC-5,10,1624,English
Karachi,Pakistan,16840000,24.8607,67.0011,Asia,UTC+5,8,1729,Urdu
Buenos Aires,Argentina,15370000,-34.6037,-58.3816,South America,UTC-3,25,1536,Spanish
Istanbul,Turkey,15850000,41.0082,28.9784,Europe,UTC+3,39,660,Turkish
Kolkata,India,15130000,22.5726,88.3639,Asia,UTC+5:30,11,1690,Bengali
Lagos,Nigeria,15950000,6.5244,3.3792,Africa,UTC+1,41,1472,English
Manila,Philippines,14410000,14.5995,120.9842,Asia,UTC+8,16,1571,Filipino
Guangzhou,China,13860000,23.1291,113.2644,Asia,UTC+8,21,214,Cantonese
Rio de Janeiro,Brazil,13630000,-22.9068,-43.1729,South America,UTC-3,11,1565,Portuguese
Lahore,Pakistan,13540000,31.5204,74.3587,Asia,UTC+5,217,1000,Punjabi
Bangalore,India,13190000,12.9716,77.5946,Asia,UTC+5:30,920,1537,Kannada
Moscow,Russia,12680000,55.7558,37.6173,Europe,UTC+3,156,1147,Russian
Shenzhen,China,12590000,22.5431,114.0579,Asia,UTC+8,1,1979,Mandarin
Paris,France,11020000,48.8566,2.3522,Europe,UTC+1,35,250,French
London,United Kingdom,9540000,51.5074,-0.1278,Europe,UTC+0,11,47,English
Lima,Peru,11040000,-12.0464,-77.0428,South America,UTC-5,161,1535,Spanish
Bangkok,Thailand,11070000,13.7563,100.5018,Asia,UTC+7,1,1782,Thai
Chennai,India,11500000,13.0827,80.2707,Asia,UTC+5:30,6,1639,Tamil
Jakarta,Indonesia,10560000,-6.2088,106.8456,Asia,UTC+7,8,397,Indonesian
Tehran,Iran,9500000,35.6892,51.3890,Asia,UTC+3:30,1189,1524,Persian
Berlin,Germany,3750000,52.5200,13.4050,Europe,UTC+1,34,1237,German
Madrid,Spain,3340000,40.4168,-3.7038,Europe,UTC+1,650,852,Spanish
Toronto,Canada,6250000,43.6532,-79.3832,North America,UTC-5,76,1793,English
Sydney,Australia,5360000,-33.8688,151.2093,Oceania,UTC+11,3,1788,English
Nairobi,Kenya,5120000,-1.2921,36.8219,Africa,UTC+3,1795,1899,Swahili
Singapore,Singapore,5920000,1.3521,103.8198,Asia,UTC+8,15,1819,English
Seoul,South Korea,9740000,37.5665,126.9780,Asia,UTC+9,38,18,Korean
Bogota,Colombia,8080000,4.7110,-74.0721,South America,UTC-5,2640,1538,Spanish
Johannesburg,South Africa,6065000,-26.2041,28.0473,Africa,UTC+2,1753,1886,Zulu
Stockholm,Sweden,1630000,59.3293,18.0686,Europe,UTC+1,28,1252,Swedish
CSV

echo "    Created: world_cities.csv (40 rows)"

# ═══════════════════════════════════════════════════════════════════════════
#  4. products.csv — Product catalog (extra tab for multi-tab screenshot)
# ═══════════════════════════════════════════════════════════════════════════

cat > "${DATA_DIR}/products.csv" << 'CSV'
SKU,Product Name,Category,Price ($),Stock,Rating,Reviews,Weight (kg),Description
PRD-1001,CloudSync Pro,Software,29.99,999999,4.7,12840,0,"Real-time file synchronization across unlimited devices with end-to-end encryption"
PRD-1002,ErgoDesk Pro,Furniture,899.00,342,4.5,2156,45.2,"Height-adjustable standing desk with programmable memory positions and cable management"
PRD-1003,QuantumKey 256,Security,149.99,8750,4.9,5623,0.02,"Hardware security key with FIDO2/WebAuthn support and biometric fingerprint reader"
PRD-1004,ArcticFlow X1,Cooling,79.99,1560,4.3,891,1.8,"CPU liquid cooler with 360mm radiator and ARGB fans for high-performance builds"
PRD-1005,NovaPad Ultra,Tablets,1199.00,2800,4.6,7432,0.48,"12.9-inch OLED display tablet with M3 chip and Apple Pencil support"
PRD-1006,BioTrack Watch,Wearables,349.99,5600,4.4,3217,0.05,"Advanced health monitoring smartwatch with ECG, SpO2, and 14-day battery life"
PRD-1007,ThunderDock 5,Accessories,249.99,4200,4.2,1843,0.35,"Thunderbolt 5 docking station with triple 4K display support and 100W charging"
PRD-1008,SonicPods Max,Audio,299.99,7800,4.8,15670,0.03,"Wireless earbuds with adaptive ANC, spatial audio, and 40-hour total battery"
PRD-1009,CipherVault NAS,Storage,1499.00,890,4.6,923,8.5,"4-bay NAS with 10GbE, hardware encryption, and automated backup scheduling"
PRD-1010,FlexCam 4K,Cameras,199.99,3400,4.1,2456,0.15,"AI-powered webcam with auto-framing, background blur, and low-light enhancement"
PRD-1011,TurboCharge 200W,Chargers,89.99,12000,4.5,4567,0.28,"GaN USB-C charger with 200W total output and 4 ports for simultaneous charging"
PRD-1012,Nexus Mesh Pro,Networking,399.99,2100,4.7,1678,2.4,"Wi-Fi 7 mesh system covering 7500 sq ft with tri-band and built-in VPN server"
PRD-1013,DataVault Enterprise,Software,149.99,999999,4.3,8901,0,"Cloud-native database management with automated scaling and point-in-time recovery"
PRD-1014,StellarKeys MX,Keyboards,169.99,6700,4.8,9234,0.85,"Mechanical keyboard with hot-swappable switches, PBT keycaps, and wireless"
PRD-1015,UltraWide 49,Monitors,1299.00,1200,4.4,3456,14.2,"49-inch curved ultrawide monitor with 5120x1440 resolution and 240Hz refresh"
PRD-1016,PowerStation 1500,Energy,999.00,780,4.6,1234,15.8,"Portable power station with 1500Wh capacity, solar input, and EV charging port"
PRD-1017,AirPurify Max,Home,449.99,3200,4.5,2789,7.3,"HEPA air purifier for rooms up to 1000 sq ft with real-time AQI monitoring"
PRD-1018,CodePilot IDE,Software,19.99,999999,4.9,21456,0,"AI-assisted code editor with multi-language support and integrated terminal"
PRD-1019,DroneX Explorer,Drones,2499.00,450,4.7,867,1.2,"Professional drone with 8K camera, 45-min flight time, and obstacle avoidance"
PRD-1020,SmartLock Ultra,Smart Home,279.99,5400,4.3,3456,0.95,"Biometric smart lock with fingerprint, face recognition, and Apple Home support"
PRD-1021,SecureAuth Plus,Software,79.99,999999,4.4,6789,0,"Multi-factor authentication platform with SSO and zero-trust architecture"
PRD-1022,GraphPad Studio,Software,59.99,999999,4.6,4321,0,"Data visualization tool with 50+ chart types and real-time collaboration"
PRD-1023,PeakFit Band,Wearables,129.99,8900,4.2,5678,0.03,"Fitness tracker with GPS, heart rate zones, and personalized workout coaching"
PRD-1024,HyperSSD 4TB,Storage,299.99,4500,4.8,7890,0.06,"PCIe 5.0 NVMe SSD with 12,400 MB/s sequential read and built-in heatsink"
PRD-1025,AquaFilter Pro,Home,159.99,6700,4.5,2345,3.2,"Under-sink water filtration system with smart filter life monitoring"
CSV

echo "    Created: products.csv (25 rows)"

# ═══════════════════════════════════════════════════════════════════════════
#  5. employees.csv — Employee directory (good for search demo)
# ═══════════════════════════════════════════════════════════════════════════

cat > "${DATA_DIR}/employees.csv" << 'CSV'
ID,Name,Email,Department,Title,Office,Salary ($),Start Date,Manager,Phone
E-1001,Alice Chen,alice.chen@nexora.tech,Engineering,Senior Staff Engineer,San Francisco,245000,2019-03-15,Grace Tanaka,+1-415-555-0101
E-1002,Bob Martinez,bob.martinez@nexora.tech,Engineering,Software Engineer II,San Francisco,165000,2022-01-10,Alice Chen,+1-415-555-0102
E-1003,Carol Park,carol.park@nexora.tech,Product,Director of Product,New York,220000,2020-06-22,James Wilson,+1-212-555-0103
E-1004,David Okonkwo,david.okonkwo@nexora.tech,Engineering,Backend Engineer,London,145000,2023-04-03,Alice Chen,+44-20-5555-0104
E-1005,Elena Vasquez,elena.vasquez@nexora.tech,Design,UX Design Lead,San Francisco,195000,2021-02-14,Carol Park,+1-415-555-0105
E-1006,Frank Johansson,frank.johansson@nexora.tech,Engineering,DevOps Engineer,Stockholm,155000,2022-09-01,Alice Chen,+46-8-555-0106
E-1007,Grace Tanaka,grace.tanaka@nexora.tech,Engineering,VP of Engineering,San Francisco,310000,2018-01-08,James Wilson,+1-415-555-0107
E-1008,Hassan Al-Rashid,hassan.alrashid@nexora.tech,Sales,Enterprise Account Executive,Dubai,180000,2021-11-15,Maria Santos,+971-4-555-0108
E-1009,Ingrid Svensson,ingrid.svensson@nexora.tech,Engineering,Frontend Engineer,Stockholm,140000,2023-07-20,Frank Johansson,+46-8-555-0109
E-1010,James Wilson,james.wilson@nexora.tech,Executive,CEO,San Francisco,450000,2015-06-01,,+1-415-555-0110
E-1011,Keiko Nakamura,keiko.nakamura@nexora.tech,Data Science,Senior Data Scientist,Tokyo,210000,2020-03-28,Grace Tanaka,+81-3-5555-0111
E-1012,Lucas Bergmann,lucas.bergmann@nexora.tech,Engineering,Security Engineer,Berlin,160000,2022-05-16,Alice Chen,+49-30-555-0112
E-1013,Maria Santos,maria.santos@nexora.tech,Sales,VP of Sales,New York,285000,2019-09-09,James Wilson,+1-212-555-0113
E-1014,Nina Petrov,nina.petrov@nexora.tech,Marketing,Content Strategist,London,125000,2023-01-30,Oliver Chang,+44-20-5555-0114
E-1015,Oliver Chang,oliver.chang@nexora.tech,Marketing,Head of Marketing,San Francisco,235000,2020-08-17,James Wilson,+1-415-555-0115
E-1016,Priya Sharma,priya.sharma@nexora.tech,Engineering,Machine Learning Engineer,Bangalore,175000,2021-04-05,Keiko Nakamura,+91-80-5555-0116
E-1017,Quinn O'Brien,quinn.obrien@nexora.tech,Customer Success,Customer Success Manager,Dublin,130000,2022-11-28,Maria Santos,+353-1-555-0117
E-1018,Rafael Costa,rafael.costa@nexora.tech,Engineering,iOS Developer,Sao Paulo,145000,2023-03-12,Alice Chen,+55-11-5555-0118
E-1019,Sarah Kim,sarah.kim@nexora.tech,Finance,Financial Analyst,New York,140000,2022-07-25,Thomas Weber,+1-212-555-0119
E-1020,Thomas Weber,thomas.weber@nexora.tech,Finance,CFO,San Francisco,320000,2017-02-20,James Wilson,+1-415-555-0120
E-1021,Uma Reddy,uma.reddy@nexora.tech,Engineering,QA Engineer,Bangalore,120000,2023-06-14,Alice Chen,+91-80-5555-0121
E-1022,Viktor Lindgren,viktor.lindgren@nexora.tech,Product,Product Manager,Stockholm,170000,2021-10-03,Carol Park,+46-8-555-0122
E-1023,Wendy Zhao,wendy.zhao@nexora.tech,Engineering,Platform Engineer,San Francisco,185000,2020-12-07,Grace Tanaka,+1-415-555-0123
E-1024,Xavier Dupont,xavier.dupont@nexora.tech,Design,Visual Designer,Paris,135000,2023-02-19,Elena Vasquez,+33-1-5555-0124
E-1025,Yuki Tanaka,yuki.tanaka@nexora.tech,Engineering,Site Reliability Engineer,Tokyo,165000,2022-04-11,Grace Tanaka,+81-3-5555-0125
E-1026,Zara Hussain,zara.hussain@nexora.tech,Legal,General Counsel,London,260000,2019-07-08,James Wilson,+44-20-5555-0126
E-1027,Adrian Moreau,adrian.moreau@nexora.tech,Engineering,Database Engineer,Paris,150000,2023-08-21,Alice Chen,+33-1-5555-0127
E-1028,Bianca Rossi,bianca.rossi@nexora.tech,HR,People Operations Lead,San Francisco,155000,2021-05-30,James Wilson,+1-415-555-0128
E-1029,Chen Wei,chen.wei@nexora.tech,Engineering,Systems Architect,Beijing,200000,2019-11-11,Grace Tanaka,+86-10-5555-0129
E-1030,Diana Kowalski,diana.kowalski@nexora.tech,Sales,Sales Development Rep,New York,95000,2024-01-08,Maria Santos,+1-212-555-0130
CSV

echo "    Created: employees.csv (30 rows)"

# ═══════════════════════════════════════════════════════════════════════════
#  6. Large CSV — sensor telemetry data (generated, for "large file" demo)
# ═══════════════════════════════════════════════════════════════════════════

LARGE_CSV="${DATA_DIR}/sensor_telemetry.csv"
LARGE_ROW_COUNT="${LARGE_ROW_COUNT:-500000}"

if [[ -f "$LARGE_CSV" ]]; then
    existing_lines=$(wc -l < "$LARGE_CSV" | tr -d ' ')
    if (( existing_lines > LARGE_ROW_COUNT )); then
        echo "    Skipped: sensor_telemetry.csv already exists (${existing_lines} rows)"
    else
        echo "    Regenerating: sensor_telemetry.csv (${LARGE_ROW_COUNT} rows)..."
        generate_large=true
    fi
else
    generate_large=true
fi

if [[ "${generate_large:-false}" == "true" ]]; then
    echo "    Generating: sensor_telemetry.csv (${LARGE_ROW_COUNT} rows) — this may take a moment..."
    python3 -c "
import csv, random, sys
from datetime import datetime, timedelta

random.seed(42)
row_count = int(sys.argv[1])
output = sys.argv[2]

sensors = [f'SENSOR-{i:04d}' for i in range(1, 51)]
locations = [
    'Building A - Floor 1', 'Building A - Floor 2', 'Building A - Floor 3',
    'Building B - Floor 1', 'Building B - Floor 2',
    'Building C - Basement', 'Building C - Floor 1', 'Building C - Floor 2',
    'Warehouse North', 'Warehouse South',
    'Server Room Alpha', 'Server Room Beta',
    'Parking Garage L1', 'Parking Garage L2',
    'Rooftop Array'
]
statuses = ['normal', 'normal', 'normal', 'normal', 'warning', 'critical']

start = datetime(2024, 1, 1)
interval = timedelta(seconds=30)

with open(output, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['Timestamp', 'Sensor ID', 'Temperature (C)', 'Humidity (%)',
                'Pressure (hPa)', 'Battery (%)', 'Location', 'Status', 'Signal (dBm)'])
    for i in range(row_count):
        ts = start + interval * i
        sensor = random.choice(sensors)
        loc = locations[hash(sensor) % len(locations)]
        temp = round(18.0 + random.gauss(0, 5) + 3 * (ts.hour - 12) / 12, 1)
        humid = round(max(10, min(99, 50 + random.gauss(0, 15))), 1)
        press = round(1013.25 + random.gauss(0, 5), 2)
        batt = round(max(5, 100 - i * 0.0001 + random.gauss(0, 2)), 1)
        status = random.choice(statuses)
        signal = round(-40 + random.gauss(0, 12), 1)
        w.writerow([ts.strftime('%Y-%m-%d %H:%M:%S'), sensor, temp, humid,
                     press, batt, loc, status, signal])
" "$LARGE_ROW_COUNT" "$LARGE_CSV"
    echo "    Created: sensor_telemetry.csv (${LARGE_ROW_COUNT} rows)"
fi

echo ""
echo "==> Test data generation complete."
echo "    Directory: ${DATA_DIR}"
ls -lh "${DATA_DIR}"/*.csv | awk '{print "    " $5 "  " $NF}'

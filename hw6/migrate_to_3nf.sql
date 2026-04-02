-- 1) Countries (dimension)
INSERT INTO countries (country_name)
SELECT DISTINCT COALESCE(NULLIF(country, ''), 'Unknown') AS country_name
FROM request_logs
ON CONFLICT (country_name) DO NOTHING;

-- 2) IP -> country mapping 
INSERT INTO ip_addresses (client_ip, country_id)
SELECT
    x.client_ip,
    c.country_id
FROM (
    SELECT
        COALESCE(NULLIF(client_ip, ''), '0.0.0.0') AS client_ip,
        COALESCE(NULLIF(country, ''), 'Unknown') AS country_name,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(NULLIF(client_ip, ''), '0.0.0.0')
            ORDER BY COUNT(*) DESC, COALESCE(NULLIF(country, ''), 'Unknown')
        ) AS rn
    FROM request_logs
    GROUP BY COALESCE(NULLIF(client_ip, ''), '0.0.0.0'), COALESCE(NULLIF(country, ''), 'Unknown')
) x
JOIN countries c
    ON c.country_name = x.country_name
WHERE x.rn = 1
ON CONFLICT (client_ip) DO UPDATE
SET country_id = EXCLUDED.country_id;

-- 3) Demographics
INSERT INTO demographics (gender, age, income)
SELECT DISTINCT
    COALESCE(NULLIF(gender, ''), 'Unknown') AS gender,
    age,
    COALESCE(NULLIF(income, ''), 'Unknown') AS income
FROM request_logs
ON CONFLICT (gender, age, income) DO NOTHING;

-- 4) Request fact rows
INSERT INTO request_events (
    ip_id,
    demographic_id,
    is_banned,
    time_of_day,
    requested_file,
    request_time
)
SELECT
    ip.ip_id,
    d.demographic_id,
    r.is_banned,
    COALESCE(NULLIF(r.time_of_day, ''), '00:00:00'),
    COALESCE(NULLIF(r.requested_file, ''), ''),
    r.request_time
FROM request_logs r
JOIN ip_addresses ip
    ON ip.client_ip = COALESCE(NULLIF(r.client_ip, ''), '0.0.0.0')
JOIN demographics d
    ON d.gender = COALESCE(NULLIF(r.gender, ''), 'Unknown')
   AND d.age IS NOT DISTINCT FROM r.age
   AND d.income = COALESCE(NULLIF(r.income, ''), 'Unknown');

-- 5) Failed requests copy 
INSERT INTO failed_request_events (request_time, requested_file, error_code)
SELECT request_time, requested_file, error_code
FROM failed_request_logs;

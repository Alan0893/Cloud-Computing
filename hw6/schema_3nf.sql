CREATE TABLE IF NOT EXISTS countries (
    country_id SERIAL PRIMARY KEY,
    country_name VARCHAR(128) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS ip_addresses (
    ip_id SERIAL PRIMARY KEY,
    client_ip VARCHAR(64) NOT NULL UNIQUE,
    country_id INTEGER NOT NULL REFERENCES countries(country_id)
);

CREATE TABLE IF NOT EXISTS demographics (
    demographic_id SERIAL PRIMARY KEY,
    gender VARCHAR(32) NOT NULL,
    age INTEGER NULL,
    income VARCHAR(64) NOT NULL,
    UNIQUE (gender, age, income)
);

CREATE TABLE IF NOT EXISTS request_events (
    event_id SERIAL PRIMARY KEY,
    ip_id INTEGER NOT NULL REFERENCES ip_addresses(ip_id),
    demographic_id INTEGER NOT NULL REFERENCES demographics(demographic_id),
    is_banned BOOLEAN NOT NULL DEFAULT FALSE,
    time_of_day VARCHAR(32) NOT NULL,
    requested_file VARCHAR(256) NOT NULL,
    request_time TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS failed_request_events (
    failed_event_id SERIAL PRIMARY KEY,
    request_time TIMESTAMPTZ NOT NULL,
    requested_file VARCHAR(256) NOT NULL,
    error_code INTEGER NOT NULL
);

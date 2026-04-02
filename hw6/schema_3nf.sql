CREATE TABLE IF NOT EXISTS countries (
    country_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    country_name VARCHAR(128) NOT NULL,
    PRIMARY KEY (country_id),
    UNIQUE KEY uq_countries_country_name (country_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ip_addresses (
    ip_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    client_ip VARCHAR(64) NOT NULL,
    country_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (ip_id),
    UNIQUE KEY uq_ip_addresses_client_ip (client_ip),
    CONSTRAINT fk_ip_addresses_country FOREIGN KEY (country_id) REFERENCES countries (country_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS demographics (
    demographic_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    gender VARCHAR(32) NOT NULL,
    age INT NULL,
    income VARCHAR(64) NOT NULL,
    PRIMARY KEY (demographic_id),
    UNIQUE KEY uq_demographics_profile (gender, age, income)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS request_events (
    event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ip_id BIGINT UNSIGNED NOT NULL,
    demographic_id BIGINT UNSIGNED NOT NULL,
    is_banned TINYINT(1) NOT NULL DEFAULT 0,
    time_of_day VARCHAR(32) NOT NULL,
    requested_file VARCHAR(256) NOT NULL,
    request_time DATETIME(6) NOT NULL,
    PRIMARY KEY (event_id),
    CONSTRAINT fk_request_events_ip FOREIGN KEY (ip_id) REFERENCES ip_addresses (ip_id),
    CONSTRAINT fk_request_events_demo FOREIGN KEY (demographic_id) REFERENCES demographics (demographic_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS failed_request_events (
    failed_event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    request_time DATETIME(6) NOT NULL,
    requested_file VARCHAR(256) NOT NULL,
    error_code INT NOT NULL,
    PRIMARY KEY (failed_event_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TYPE push_platform AS ENUM ('ANDROID', 'IOS');

CREATE TABLE notification_push_tokens (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    installation_id VARCHAR(128) NOT NULL,
    token VARCHAR(4096) NOT NULL,
    platform push_platform NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ux_notification_push_tokens_user_installation
        UNIQUE (user_id, installation_id),
    CONSTRAINT ux_notification_push_tokens_token UNIQUE (token)
);

CREATE INDEX ix_notification_push_tokens_user
    ON notification_push_tokens (user_id);

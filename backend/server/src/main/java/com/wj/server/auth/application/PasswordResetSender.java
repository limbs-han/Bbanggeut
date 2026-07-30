package com.wj.server.auth.application;

public interface PasswordResetSender {
    void send(String email, String rawToken);
}

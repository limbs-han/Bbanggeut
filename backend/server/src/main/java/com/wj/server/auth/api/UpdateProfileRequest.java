package com.wj.server.auth.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/// 프로필 수정 요청. 지금은 표시 이름만 바꾼다 — 이메일은 로그인 식별자라
/// 여기서 건드리지 않는다.
public record UpdateProfileRequest(
    @NotBlank @Size(max = 60) String displayName
) {
}

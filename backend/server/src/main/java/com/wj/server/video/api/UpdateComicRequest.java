package com.wj.server.video.api;

import jakarta.validation.constraints.Size;

/**
 * 만화 제목 바꾸기.
 *
 * <p>빈 문자열은 "붙인 제목을 지운다"는 뜻이고, 그러면 원본 영상 제목으로
 * 되돌아간다 — 제목을 지울 길이 없으면 한번 잘못 붙인 이름을 되돌릴 수 없다.
 *
 * @param title 새 제목. 비었으면 원본 제목을 쓴다
 */
public record UpdateComicRequest(@Size(max = 200) String title) {
}

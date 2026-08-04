package com.wj.server.stream.infrastructure;

/** MediaMTX 관리 API에서 경로(스트림) 상태를 읽는다. */
public interface MediaMtxClient {
    enum PathState {
        /** 경로가 존재하고 publisher가 준비됨(ready=true). */
        READY,
        /** 경로가 없거나 publisher가 붙어 있지 않음. */
        NOT_READY,
        /** API에 닿지 못함 — 판단 불가. 이 값으로는 아무것도 실패 처리하지 않는다. */
        UNKNOWN
    }

    PathState pathState(String name);
}

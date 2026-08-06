package com.wj.server.device.api;

import com.fasterxml.jackson.annotation.JsonSetter;

public final class UpdateDeviceRequest {
    private String name;
    private Integer retentionDays;
    private Boolean detectionEnabled;
    private boolean namePresent;
    private boolean retentionDaysPresent;
    private boolean detectionEnabledPresent;

    public String name() { return name; }
    public Integer retentionDays() { return retentionDays; }
    public Boolean detectionEnabled() { return detectionEnabled; }
    public boolean namePresent() { return namePresent; }
    public boolean retentionDaysPresent() { return retentionDaysPresent; }
    public boolean detectionEnabledPresent() { return detectionEnabledPresent; }

    @JsonSetter("name")
    public void setName(String name) {
        this.name = name;
        this.namePresent = true;
    }

    @JsonSetter("retentionDays")
    public void setRetentionDays(Integer retentionDays) {
        this.retentionDays = retentionDays;
        this.retentionDaysPresent = true;
    }

    /** 감지·저장 스위치. false면 서버가 이 기기의 영상 업로드를 거절한다. */
    @JsonSetter("detectionEnabled")
    public void setDetectionEnabled(Boolean detectionEnabled) {
        this.detectionEnabled = detectionEnabled;
        this.detectionEnabledPresent = true;
    }
}

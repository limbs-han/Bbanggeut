package com.wj.server.device.api;

import com.fasterxml.jackson.annotation.JsonSetter;

public final class UpdateDeviceRequest {
    private String name;
    private Integer retentionDays;
    private boolean namePresent;
    private boolean retentionDaysPresent;

    public String name() { return name; }
    public Integer retentionDays() { return retentionDays; }
    public boolean namePresent() { return namePresent; }
    public boolean retentionDaysPresent() { return retentionDaysPresent; }

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
}

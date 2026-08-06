package com.wj.server.video.api;

import com.fasterxml.jackson.annotation.JsonSetter;

public final class UpdateVideoRequest {
    private String title;
    private Boolean favorite;
    private boolean titlePresent;
    private boolean favoritePresent;

    public String title() { return title; }
    public Boolean favorite() { return favorite; }
    public boolean titlePresent() { return titlePresent; }
    public boolean favoritePresent() { return favoritePresent; }

    @JsonSetter("title")
    public void setTitle(String title) {
        this.title = title;
        this.titlePresent = true;
    }

    @JsonSetter("isFavorite")
    public void setFavorite(Boolean favorite) {
        this.favorite = favorite;
        this.favoritePresent = true;
    }
}

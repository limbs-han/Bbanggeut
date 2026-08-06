package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.CreateVideoCommentRequest;
import com.wj.server.video.api.UpdateComicRequest;
import com.wj.server.video.api.UpdateVideoCommentRequest;
import com.wj.server.video.domain.ComicRow;
import com.wj.server.video.domain.VideoCommentRow;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.ComicMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ComicFeedServiceTest {
    private static final UUID USER_ID = UUID.randomUUID();
    private static final UUID OTHER_USER_ID = UUID.randomUUID();
    private static final UUID VAULT_ID = UUID.randomUUID();
    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final UUID DEVICE_ID = UUID.randomUUID();
    private static final UUID COMMENT_ID = UUID.randomUUID();
    private static final Instant MADE_AT = Instant.parse("2026-08-05T10:00:00Z");

    @Mock
    private ComicMapper comicMapper;
    @Mock
    private VideoMapper videoMapper;

    private ComicFeedService service() {
        return new ComicFeedService(comicMapper, videoMapper);
    }

    private VideoRow video() {
        return new VideoRow(
            VIDEO_ID, DEVICE_ID, "IOT_CAPTURE", "LAUGHTER", "event-1", "웃음 영상",
            "video/mp4", 100L, "a".repeat(64), 5000L,
            MADE_AT, MADE_AT.plusSeconds(5), "private/device/video.mp4", "READY", false,
            MADE_AT, "LAUGHTER");
    }

    private ComicRow comic(String title, int likes, boolean likedByMe) {
        return comic(title, likes, likedByMe, false, "MEMBER");
    }

    private ComicRow comic(
        String title, int likes, boolean likedByMe, boolean mine, String myRole
    ) {
        return new ComicRow(
            VIDEO_ID, title, "웃음 영상", MADE_AT, likes, likedByMe, 2, mine, myRole);
    }

    private void accessible() {
        when(videoMapper.findAccessibleVideo(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(video()));
    }

    @Test
    void feedFallsBackToTheSourceTitleWhenNoTitleWasGiven() {
        when(comicMapper.findByVault(USER_ID, VAULT_ID, 100))
            .thenReturn(List.of(comic(null, 3, true)));

        var feed = service().listByVault(USER_ID, VAULT_ID);

        assertThat(feed).hasSize(1);
        assertThat(feed.get(0).title()).isEqualTo("웃음 영상");
        assertThat(feed.get(0).customTitle()).isFalse();
        assertThat(feed.get(0).likeCount()).isEqualTo(3);
        assertThat(feed.get(0).likedByMe()).isTrue();
    }

    @Test
    void aGivenTitleWins() {
        when(comicMapper.findByVault(USER_ID, VAULT_ID, 100))
            .thenReturn(List.of(comic("우리집 만화", 0, false)));

        var feed = service().listByVault(USER_ID, VAULT_ID);

        assertThat(feed.get(0).title()).isEqualTo("우리집 만화");
        assertThat(feed.get(0).customTitle()).isTrue();
    }

    /** 제목을 지우면 원본 제목으로 되돌아간다 — 잘못 붙인 이름을 되돌릴 길이다. */
    @Test
    void blankTitleClearsTheGivenTitle() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));

        var updated = service().updateTitle(USER_ID, VIDEO_ID, new UpdateComicRequest("   "));

        verify(comicMapper).updateTitle(VIDEO_ID, null);
        assertThat(updated.title()).isEqualTo("웃음 영상");
        assertThat(updated.customTitle()).isFalse();
    }

    @Test
    void titleIsTrimmedBeforeSaving() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(comic("우리집 만화", 0, false)));

        service().updateTitle(USER_ID, VIDEO_ID, new UpdateComicRequest("  우리집 만화 "));

        verify(comicMapper).updateTitle(VIDEO_ID, "우리집 만화");
    }

    /** 같은 값을 두 번 보내도 개수가 어긋나지 않아야 한다(앱 연타·재전송). */
    @Test
    void likingTwiceKeepsOneLike() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 1, true)));

        var first = service().setLiked(USER_ID, VIDEO_ID, true);
        var second = service().setLiked(USER_ID, VIDEO_ID, true);

        assertThat(first.likeCount()).isEqualTo(1);
        assertThat(second.likeCount()).isEqualTo(1);
        assertThat(second.likedByMe()).isTrue();
    }

    @Test
    void unlikeRemovesMyLike() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));

        var result = service().setLiked(USER_ID, VIDEO_ID, false);

        verify(comicMapper).unlike(VIDEO_ID, USER_ID);
        assertThat(result.likedByMe()).isFalse();
    }

    /**
     * 남의 금고 영상은 만화가 있는지조차 알려주지 않는다. 권한을 먼저 보므로
     * 만화 조회까지 가지 않는다.
     */
    @Test
    void anInaccessibleVideoIsNotFoundAndNeverTouchesTheComic() {
        when(videoMapper.findAccessibleVideo(USER_ID, VIDEO_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service().listComments(USER_ID, VIDEO_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("리소스를 찾을 수 없습니다");
        verify(comicMapper, never()).findComments(eq(VIDEO_ID), anyInt());
    }

    @Test
    void aVideoWithoutAComicIsNotFound() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(
            () -> service().addComment(USER_ID, VIDEO_ID, new CreateVideoCommentRequest("하하")))
            .isInstanceOf(ApiException.class);
    }

    @Test
    void commentsComeBackWithTheAuthorNameFromUsers() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));
        when(comicMapper.findComments(VIDEO_ID, 200)).thenReturn(List.of(
            new VideoCommentRow(COMMENT_ID, OTHER_USER_ID, "엄마", "귀엽다", MADE_AT)));

        var comments = service().listComments(USER_ID, VIDEO_ID);

        assertThat(comments).hasSize(1);
        assertThat(comments.get(0).authorName()).isEqualTo("엄마");
        assertThat(comments.get(0).body()).isEqualTo("귀엽다");
    }

    @Test
    void anEmptyCommentIsRefused() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));

        assertThatThrownBy(
            () -> service().addComment(USER_ID, VIDEO_ID, new CreateVideoCommentRequest("   ")))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("댓글 내용");
    }

    @Test
    void onlyTheAuthorCanEditTheirComment() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));
        when(comicMapper.findCommentAuthorId(COMMENT_ID, VIDEO_ID))
            .thenReturn(Optional.of(OTHER_USER_ID));

        assertThatThrownBy(() -> service().updateComment(
            USER_ID, VIDEO_ID, COMMENT_ID, new UpdateVideoCommentRequest("고친 말")))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("자신이 쓴 댓글만");
    }

    /** 남의 댓글이어도 OWNER는 지운다 — 부적절한 댓글을 걷어낼 길이 필요하다. */
    @Test
    void theVaultOwnerCanDeleteSomeoneElsesComment() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));
        when(comicMapper.findCommentAuthorId(COMMENT_ID, VIDEO_ID))
            .thenReturn(Optional.of(OTHER_USER_ID));
        when(videoMapper.findActiveRole(USER_ID, VIDEO_ID)).thenReturn(Optional.of("OWNER"));
        when(comicMapper.deleteComment(COMMENT_ID, VIDEO_ID)).thenReturn(1);

        service().deleteComment(USER_ID, VIDEO_ID, COMMENT_ID);

        verify(comicMapper).deleteComment(COMMENT_ID, VIDEO_ID);
    }

    /** 남이 만든 만화를 MEMBER가 지울 수는 없다. */
    @Test
    void aMemberCannotDeleteSomeoneElsesComic() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(comic(null, 0, false, false, "MEMBER")));

        assertThatThrownBy(() -> service().requireDeletable(USER_ID, VIDEO_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("만든 사람이나 OWNER만");
        verify(comicMapper, never()).delete(VIDEO_ID);
    }

    /** 잘못 만든 만화는 자기 손으로 치울 수 있어야 한다. */
    @Test
    void theCreatorMayDeleteTheirOwnComic() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(comic(null, 0, false, true, "MEMBER")));

        service().requireDeletable(USER_ID, VIDEO_ID);
        service().delete(VIDEO_ID);

        verify(comicMapper).delete(VIDEO_ID);
    }

    /** 만든 사람이 나간 뒤에도 누군가는 정리할 수 있어야 한다. */
    @Test
    void theVaultOwnerMayDeleteAnyComic() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(comic(null, 0, false, false, "OWNER")));

        service().requireDeletable(USER_ID, VIDEO_ID);
        service().delete(VIDEO_ID);

        verify(comicMapper).delete(VIDEO_ID);
    }

    /** V45 이전 만화는 만든 사람을 남기지 않았다 — OWNER만 지운다. */
    @Test
    void anOldComicWithoutACreatorIsOwnerOnly() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID))
            .thenReturn(Optional.of(comic(null, 0, false, false, "EDITOR")));

        assertThatThrownBy(() -> service().requireDeletable(USER_ID, VIDEO_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("만든 사람이나 OWNER만");
    }

    /** 앱이 규칙을 다시 계산하지 않도록 목록이 판정을 함께 준다. */
    @Test
    void theFeedTellsTheAppWhichComicsItMayDelete() {
        when(comicMapper.findByVault(USER_ID, VAULT_ID, 100)).thenReturn(List.of(
            comic("내가 만든 것", 0, false, true, "MEMBER"),
            comic("남이 만든 것", 0, false, false, "MEMBER")));

        var feed = service().listByVault(USER_ID, VAULT_ID);

        assertThat(feed.get(0).canDelete()).isTrue();
        assertThat(feed.get(1).canDelete()).isFalse();
    }

    /** 만화가 없는 영상은 404다 — 있는지 여부를 403과 404의 차이로 흘리지 않는다. */
    @Test
    void deletingAComicThatIsNotThereIsNotFound() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service().requireDeletable(USER_ID, VIDEO_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("리소스를 찾을 수 없습니다");
        verify(comicMapper, never()).delete(VIDEO_ID);
    }

    @Test
    void aMemberCannotDeleteSomeoneElsesComment() {
        accessible();
        when(comicMapper.find(USER_ID, VIDEO_ID)).thenReturn(Optional.of(comic(null, 0, false)));
        when(comicMapper.findCommentAuthorId(COMMENT_ID, VIDEO_ID))
            .thenReturn(Optional.of(OTHER_USER_ID));
        when(videoMapper.findActiveRole(USER_ID, VIDEO_ID)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service().deleteComment(USER_ID, VIDEO_ID, COMMENT_ID))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("OWNER만");
        verify(comicMapper, never()).deleteComment(COMMENT_ID, VIDEO_ID);
    }
}

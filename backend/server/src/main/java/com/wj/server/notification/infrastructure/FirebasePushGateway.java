package com.wj.server.notification.infrastructure;

import java.util.ArrayList;
import java.util.List;

import com.google.firebase.messaging.AndroidConfig;
import com.google.firebase.messaging.AndroidConfig.Priority;
import com.google.firebase.messaging.ApnsConfig;
import com.google.firebase.messaging.Aps;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingException;
import com.google.firebase.messaging.MessagingErrorCode;
import com.google.firebase.messaging.MulticastMessage;
import com.google.firebase.messaging.Notification;
import com.wj.server.notification.application.PushGateway;
import com.wj.server.notification.domain.PushMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "app.push.enabled", havingValue = "true")
public class FirebasePushGateway implements PushGateway {
    private static final Logger log = LoggerFactory.getLogger(FirebasePushGateway.class);
    private static final int MAX_MULTICAST_TOKENS = 500;

    private final FirebaseMessaging messaging;

    public FirebasePushGateway(FirebaseMessaging messaging) {
        this.messaging = messaging;
    }

    @Override
    @SuppressWarnings("deprecation") // Flutter currently registers FCM tokens; FID migration is separate.
    public List<String> send(List<String> tokens, PushMessage message) {
        var invalidTokens = new ArrayList<String>();
        for (int from = 0; from < tokens.size(); from += MAX_MULTICAST_TOKENS) {
            var chunk = tokens.subList(from, Math.min(from + MAX_MULTICAST_TOKENS, tokens.size()));
            try {
                var multicast = MulticastMessage.builder()
                    .setNotification(Notification.builder()
                        .setTitle(message.title())
                        .setBody(message.body())
                        .build())
                    .putAllData(message.data())
                    .setAndroidConfig(AndroidConfig.builder().setPriority(Priority.HIGH).build())
                    .setApnsConfig(ApnsConfig.builder()
                        .putHeader("apns-priority", "10")
                        .setAps(Aps.builder().setSound("default").build())
                        .build())
                    .addAllTokens(chunk)
                    .build();
                var response = messaging.sendEachForMulticast(multicast);
                for (int index = 0; index < response.getResponses().size(); index++) {
                    var sendResponse = response.getResponses().get(index);
                    if (!sendResponse.isSuccessful() && isInvalid(sendResponse.getException())) {
                        invalidTokens.add(chunk.get(index));
                    }
                }
                if (response.getFailureCount() > 0) {
                    log.warn("FCM multicast completed with {} failures out of {} messages",
                        response.getFailureCount(), chunk.size());
                }
            } catch (FirebaseMessagingException exception) {
                log.error("FCM multicast request failed", exception);
            }
        }
        return invalidTokens;
    }

    private boolean isInvalid(FirebaseMessagingException exception) {
        if (exception == null) {
            return false;
        }
        return exception.getMessagingErrorCode() == MessagingErrorCode.UNREGISTERED
            || exception.getMessagingErrorCode() == MessagingErrorCode.INVALID_ARGUMENT;
    }
}

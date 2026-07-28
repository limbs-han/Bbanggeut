package com.wj.server.notification.infrastructure;

import java.io.IOException;

import com.google.auth.oauth2.GoogleCredentials;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;
import com.wj.server.config.PushProperties;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConditionalOnProperty(name = "app.push.enabled", havingValue = "true")
public class FirebasePushConfiguration {
    @Bean
    public FirebaseApp firebaseApp(PushProperties properties) throws IOException {
        var options = FirebaseOptions.builder()
            .setCredentials(GoogleCredentials.getApplicationDefault());
        if (properties.projectId() != null && !properties.projectId().isBlank()) {
            options.setProjectId(properties.projectId());
        }
        return FirebaseApp.initializeApp(options.build());
    }

    @Bean
    public FirebaseMessaging firebaseMessaging(FirebaseApp firebaseApp) {
        return FirebaseMessaging.getInstance(firebaseApp);
    }
}

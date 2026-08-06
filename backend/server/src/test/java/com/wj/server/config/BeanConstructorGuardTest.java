package com.wj.server.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import org.springframework.core.type.filter.AnnotationTypeFilter;
import org.springframework.stereotype.Component;
import org.springframework.stereotype.Controller;
import org.springframework.stereotype.Repository;
import org.springframework.stereotype.Service;

/**
 * 생성자가 둘 이상인 빈은 스프링이 쓸 쪽을 표시해 두어야 한다.
 *
 * <p><b>왜 이 테스트가 있나</b>: 2026-08-06 master 배포가
 * {@code VideoThumbnailService}에서 죽었다 — 공개 생성자(스프링용)와 패키지
 * 전용 생성자(테스트가 실행자·시계를 넣는 용도) 둘을 두고 {@code @Autowired}를
 * 빠뜨렸다. 스프링은 고를 수 없으니 기본 생성자를 찾다가 실패하고, 배포
 * 스크립트가 새 슬롯이 안 뜬 것을 보고 이전 릴리즈로 되돌렸다.
 *
 * <p>단위 테스트는 생성자를 직접 부르므로 이것을 못 잡는다. 컨텍스트를 실제로
 * 띄우는 테스트는 도커가 필요해 로컬에서 건너뛴다. 그래서 <b>리플렉션으로만</b>
 * 보는 감시선을 둔다 — 어디서든 돌고, 새 빈이 생길 때마다 저절로 적용된다.
 *
 * <p>실패하면 고칠 곳은 하나다: 스프링이 써야 하는 생성자에
 * {@code @Autowired}를 붙인다.
 */
class BeanConstructorGuardTest {
    private static final String BASE_PACKAGE = "com.wj.server";

    @Test
    void everyBeanWithSeveralConstructorsMarksTheOneSpringShouldUse() {
        List<String> offenders = new ArrayList<>();
        for (Class<?> bean : beanClasses()) {
            Constructor<?>[] constructors = bean.getDeclaredConstructors();
            if (constructors.length < 2) {
                continue;
            }
            long marked = Arrays.stream(constructors)
                .filter(constructor -> constructor.isAnnotationPresent(Autowired.class))
                .count();
            if (marked != 1) {
                offenders.add("%s: 생성자 %d개 중 @Autowired %d개"
                    .formatted(bean.getName(), constructors.length, marked));
            }
        }
        assertThat(offenders)
            .as("생성자가 둘 이상인 빈은 스프링이 쓸 생성자에 @Autowired를 붙여야 "
                + "한다. 빠뜨리면 컨텍스트가 뜨지 않아 배포가 롤백된다")
            .isEmpty();
    }

    /** 컴포넌트 스캔이 빈으로 집어 갈 클래스들. 스프링이 보는 것과 같은 눈이다. */
    private static List<Class<?>> beanClasses() {
        var scanner = new ClassPathScanningCandidateComponentProvider(false);
        for (Class<? extends java.lang.annotation.Annotation> stereotype :
            List.of(Component.class, Service.class, Repository.class, Controller.class)) {
            scanner.addIncludeFilter(new AnnotationTypeFilter(stereotype));
        }
        List<Class<?>> classes = new ArrayList<>();
        for (var candidate : scanner.findCandidateComponents(BASE_PACKAGE)) {
            String name = candidate.getBeanClassName();
            if (name == null) {
                continue;
            }
            try {
                classes.add(Class.forName(name));
            } catch (ClassNotFoundException | NoClassDefFoundError ignored) {
                // 스캔은 바이트코드만 읽으므로 못 여는 클래스가 있을 수 있다.
                // 그런 클래스는 어차피 컨텍스트에도 못 올라간다.
            }
        }
        return classes;
    }

    /** 감시선이 실제로 무언가를 보고 있는지 — 0개를 훑고 통과하면 의미가 없다. */
    @Test
    void theGuardActuallyScansThisCodebase() {
        assertThat(beanClasses()).hasSizeGreaterThan(20);
    }
}

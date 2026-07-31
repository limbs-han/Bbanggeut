package com.wj.server.config;

import java.sql.CallableStatement;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.util.UUID;

import org.apache.ibatis.type.BaseTypeHandler;
import org.apache.ibatis.type.JdbcType;
import org.apache.ibatis.type.MappedTypes;

/**
 * MyBatis ships no handler for {@link UUID}.
 *
 * <p>A uuid column read into a record field still works, because the field is
 * filled through the result map. A mapper that selects a bare uuid column into
 * {@code Optional<UUID>} does not: MyBatis treats the unknown type as a bean
 * and tries to construct it, which fails on the private {@code UUID(byte[])}
 * constructor. The vault-scoped mappers are the first to return such scalars,
 * so the handler is registered globally.
 */
@MappedTypes(UUID.class)
public class UuidTypeHandler extends BaseTypeHandler<UUID> {
    @Override
    public void setNonNullParameter(
        PreparedStatement ps, int i, UUID parameter, JdbcType jdbcType
    ) throws SQLException {
        ps.setObject(i, parameter, Types.OTHER);
    }

    @Override
    public UUID getNullableResult(ResultSet rs, String columnName) throws SQLException {
        return toUuid(rs.getObject(columnName));
    }

    @Override
    public UUID getNullableResult(ResultSet rs, int columnIndex) throws SQLException {
        return toUuid(rs.getObject(columnIndex));
    }

    @Override
    public UUID getNullableResult(CallableStatement cs, int columnIndex) throws SQLException {
        return toUuid(cs.getObject(columnIndex));
    }

    private UUID toUuid(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof UUID uuid) {
            return uuid;
        }
        return UUID.fromString(value.toString());
    }
}

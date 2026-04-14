package com.studenttracker.entity;

import jakarta.persistence.*;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;

@Entity
@Table(name = "users")
@Data                    // Lombok: generates getters, setters, toString, equals
@NoArgsConstructor       // Lombok: generates a no-args constructor (required by JPA)
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY) // maps to SERIAL in PostgreSQL
    @Column(name = "user_id")
    private Integer userId;

    // MAHE ID is the unique institutional identifier (e.g., "230905001")
    @Column(name = "mahe_id", nullable = false, unique = true, length = 20)
    private String maheId;

    @Column(name = "full_name", nullable = false, length = 120)
    private String fullName;

    @Column(name = "email", nullable = false, unique = true, length = 200)
    private String email;

    // We NEVER store plain-text passwords — always a bcrypt hash
    @Column(name = "password_hash", nullable = false)
    private String passwordHash;

    @Column(name = "branch", length = 80)
    private String branch;

    @Column(name = "semester")
    private Integer semester;

    @Column(name = "academic_year")
    private Integer academicYear;

    @Column(name = "is_active", nullable = false)
    private Boolean isActive = true;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @Column(name = "updated_at")
    private OffsetDateTime updatedAt;

    // One user can have many enrolments (one-to-many relationship)
    // mappedBy = "user" means the foreign key lives in the Enrolment entity
    // CascadeType.ALL means if we delete a user, their enrolments also get deleted
    @OneToMany(mappedBy = "user", cascade = CascadeType.ALL, fetch = FetchType.LAZY)
    private List<Enrolment> enrolments = new ArrayList<>();

    // One user can have many tasks
    @OneToMany(mappedBy = "user", cascade = CascadeType.ALL, fetch = FetchType.LAZY)
    private List<Task> tasks = new ArrayList<>();

    // One user can have many events
    @OneToMany(mappedBy = "user", cascade = CascadeType.ALL, fetch = FetchType.LAZY)
    private List<Event> events = new ArrayList<>();

    // Set timestamps automatically before saving
    @PrePersist
    protected void onCreate() {
        createdAt = OffsetDateTime.now();
        updatedAt = OffsetDateTime.now();
    }

    @PreUpdate
    protected void onUpdate() {
        updatedAt = OffsetDateTime.now();
    }
}

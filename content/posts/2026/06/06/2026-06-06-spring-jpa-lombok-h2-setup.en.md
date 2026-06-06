---
title: "Building a Data Persistence Layer Using Jakarta Persistence and Lombok in Spring Boot 3.x"
slug: "spring-jpa-lombok-h2-setup"
date: 2026-06-06T09:50:49+09:00
draft: false
image: ""
description: "This article explains the implementation specifications and precautions for integrating Jakarta Persistence (JPA), Lombok, and the H2 database to build a robust data persistence layer in a Spring Boot 3.x environment."
categories: ["Backend Architecture"]
tags: ["spring-data-jpa", "lombok", "h2-database", "jakarta-persistence", "ddl-auto"]
author: "K-Life Hack"
---

# 1. Database Persistence and Object-Relational Mapping

In modern web application architecture, data lifecycle management is an extremely critical element. While MVC patterns and RESTful APIs process HTTP requests and return responses, data processed only in memory is lost upon application termination or system failure. To ensure persistence, integration with persistent storage such as relational databases (RDBMS) is indispensable.


However, a structural mismatch known as the "object-relational impedance mismatch" exists between the object-oriented paradigm of Java (classes, encapsulation, relationships) and the relational database paradigm (tables, rows, columns, foreign key constraints). Traditionally, resolving this mismatch required manually writing redundant and error-prone SQL queries.


To address this challenge, <b>Jakarta Persistence (formerly Java Persistence API: JPA)</b> was standardized. JPA functions as an object-relational mapping (ORM) framework, mapping Java objects directly to database tables, thereby providing an environment where developers can intuitively manipulate data without having to be conscious of SQL.



## 2. H2 Database Characteristics and Operating Modes

During the development, testing, and prototyping phases, setting up production databases (such as PostgreSQL or Oracle) in a local environment increases infrastructure overhead. To address this challenge, <b>H2 Database</b>, a lightweight Java-based open-source relational database, is widely used.


Because the H2 database operates as a lightweight JAR file embedded within the application runtime, it requires no installation hassle. Two operating modes are provided: "Embedded Mode," where the database runs within the same JVM as the application, and "Server Mode," where it runs as an independent process and allows simultaneous connections from multiple external applications. It also features an in-memory capability ideal for fast integration testing where data does not need to be retained beyond the application's execution lifecycle, as well as a Web Console feature to manipulate the database via a browser. By default, it is accessible from the following URL:



```text
http://localhost:8081/h2-console
```

## 3. Evolution of Database Access: From JDBC to JPA

Before ORM frameworks became widespread, Java applications communicated with databases using <b>Java Database Connectivity (JDBC)</b>. With JDBC, it was necessary to manually manage low-level database resources, construct SQL strings, and map result sets to Java objects.



```java
Connection conn = null;
PreparedStatement pstmt = null;
ResultSet rs = null;
try {
    conn = DriverManager.getConnection(URL, USER, PASSWORD);
    String sql = "SELECT id, name, email FROM students WHERE id = ?";
    pstmt = conn.prepareStatement(sql);
    pstmt.setLong(1, 1L);
    rs = pstmt.executeQuery();
    if (rs.next()) {
        Student student = new Student();
        student.setId(rs.getLong("id"));
        student.setName(rs.getString("name"));
        student.setEmail(rs.getString("email"));
    }
} catch (SQLException e) {
    e.printStackTrace();
} finally {
    if (rs != null) try { rs.close(); } catch (SQLException e) {}
    if (pstmt != null) try { pstmt.close(); } catch (SQLException e) {}
    if (conn != null) try { conn.close(); } catch (SQLException e) {}
}
```

The main challenges of JDBC include the fact that non-essential boilerplate code—such as establishing connections, handling exceptions, and releasing resources—comprises the majority of the code; SQL queries are hardcoded as strings, meaning no compile-time type checking is performed; and the task of extracting values from a <code>ResultSet</code> and manually mapping them to domain objects is highly prone to errors like typos.


JPA abstracts these low-level JDBC operations. Instead of writing imperative SQL, developers use annotations to declare mappings on domain objects. The JPA provider (primarily Hibernate) automatically generates and executes the appropriate SQL at runtime.



```java
@PersistenceContext
private EntityManager em;

public Student findStudent(Long id) {
    return em.find(Student.class, id);
}

public void saveStudent(Student student) {
    em.persist(student);
}
```

By introducing JPA, common CRUD operations are abstracted, and the Java class structure is automatically converted into a relational schema, thereby resolving the impedance mismatch.



## 4. Dependency Definition and Environment Setup

This is a configuration example of a Gradle build definition file for using JPA and the H2 database in a Spring Boot application.



```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    runtimeOnly 'com.h2database:h2'
    compileOnly 'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}
```

## 5. Entity Mapping Specifications with Jakarta Persistence (JPA)

Entities are lightweight domain objects mapped to database tables. Since Spring Boot 3.x, the persistence specification has migrated from the traditional Java EE namespace (<code>javax.persistence.*</code>) to the Jakarta EE namespace (<code>jakarta.persistence.*</code>).


A key JPA mapping annotation is <code>@Entity</code>, which indicates that the target class is a JPA entity and is mapped to a database table. By default, the class name becomes the table name, but it can be explicitly specified using the <code>@Table</code> annotation.



```java
@Entity
@Table(name = "students")
public class Student {
    // ...
}
```

All JPA entities must define a primary key (PK) to uniquely identify records. <code>@Id</code> designates a field as the primary key, and <code>@GeneratedValue</code> configures the primary key generation strategy. Specifying <code>GenerationType.IDENTITY</code> delegates generation to the database's auto-increment feature.


Additionally, the mapping between fields and database columns can be customized using the <code>@Column</code> annotation.



```java
@Column(name = "email", nullable = false, length = 50, unique = true)
private String email;
```

Setting <code>nullable</code> to <code>false</code> applies a <code>NOT NULL</code> constraint to the generated DDL. <code>length</code> defines the maximum length of a string column, and <code>unique</code> applies a unique constraint to the column.



## 6. Lombok Integration and Anti-Patterns in Entity Design

In standard Java encapsulation patterns, fields are set to <code>private</code>, and public Getters/Setters are provided. Additionally, JPA requires a default constructor for instantiation via reflection. Writing these manually bloats the code, so Lombok is introduced to automatically generate them at compile time.



```java
@Entity
@Table(name = "students")
@Getter
@Setter
@NoArgsConstructor
public class Student {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 50)
    private String name;

    @Column(nullable = false, length = 50, unique = true)
    private String email;
}
```

⚠️ <b>Critical Warning: Avoiding @Data in JPA Entities</b>


While Lombok's <code>@Data</code> annotation is convenient because it applies <code>@Getter</code>, <code>@Setter</code>, <code>@ToString</code>, <code>@EqualsAndHashCode</code>, and <code>@RequiredArgsConstructor</code> all at once, its application to JPA entities should be avoided.


<code>@ToString</code> and <code>@EqualsAndHashCode</code> evaluate all fields within the class. If bidirectional associations (such as <code>@OneToMany</code> and <code>@ManyToOne</code>) exist between entities, calling <code>toString()</code> or <code>hashCode()</code> triggers mutual references, ultimately causing a <code>StackOverflowError</code>. For this reason, it is recommended to explicitly declare <code>@Getter</code>, <code>@Setter</code>, and <code>@NoArgsConstructor</code> individually on entity classes.



## 7. Automatic DDL Generation (ddl-auto) and Application Configuration

In Spring Boot, database connections, the H2 console, and Hibernate's DDL generation behavior can be controlled via <code>application.yaml</code>.



```yaml
spring:
  datasource:
    url: jdbc:h2:mem:testdb;DB_CLOSE_DELAY=-1
    driver-class-name: org.h2.Driver
    username: sa
    password:
  h2:
    console:
      enabled: true
      path: /h2-console
  jpa:
    hibernate:
      ddl-auto: update
    show-sql: true
    properties:
      hibernate:
        format_sql: true
```

The configuration values for <code>spring.jpa.hibernate.ddl-auto</code> and their safety in production environments are as follows:



| Option | Description | Safety in Production |
| :--- | :--- | :--- |
| `create` | Drops existing tables and creates new tables upon startup. | <b>Extremely Dangerous</b> (Data Loss) |
| `create-drop` | Similar to `create`, but drops all tables when the application terminates. | <b>Extremely Dangerous</b> (Data Loss) |
| `update` | Detects changes in entities and alters the table structure. Existing data and columns are not deleted. | <b>Dangerous</b> (Causes table locks or inconsistencies) |
| `validate` | Validates the database schema against entity definitions and halts startup if there are mismatches. | <b>Safe</b> (Recommended for Production) |
| `none` | Does not perform automatic generation. | <b>Safe</b> (Recommended for Production) |

While <code>create</code> or <code>update</code> are convenient in local development environments, to prevent unexpected data loss in production environments, always set it to <code>validate</code> or <code>none</code>, and manage the schema using dedicated migration tools such as Flyway or Liquibase.



## 8. API Verification and CORS Avoidance

To verify the operation of the constructed persistence layer and REST API, use an API client such as Postman.



```bash
curl -X POST http://localhost:8081/api/students \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "email": "john.doe@example.com"}'
```

When using the browser version of Postman, requests to the local server (<code>localhost</code>) may be blocked by CORS restrictions due to the Same-Origin Policy. In this case, installing and running the <b>Postman Agent</b> on your local machine bypasses browser restrictions and routes requests directly to the local Spring Boot server.


The main HTTP request verification steps are as follows:



1. <b>Data Registration (POST)</b>
   URL: <code>http://localhost:8081/api/students</code>
   Headers: <code>Content-Type: application/json</code>
   Body (raw JSON):

```json
{
  "name": "John Doe",
  "email": "john.doe@example.com"
}
```

2. <b>Data Retrieval (GET)</b>
   URL: <code>http://localhost:8081/api/students</code>
   Verify that the registered data is returned as a JSON array.

## 9. Configuration Notes

💡 To maintain a robust data persistence layer, apply the following checklist as your design criteria.


<b>Required Entity Components</b>
- <code>@Entity</code> must be applied at the class level.
- A primary key definition using <code>@Id</code> must exist.
- A default constructor complying with JPA specifications (<code>@NoArgsConstructor</code>) must be defined.

<b>Lombok Application Criteria</b>
- Avoid using <code>@Data</code>, and apply <code>@Getter</code> and <code>@Setter</code> individually.
- If bidirectional associations exist, the design must prevent <code>StackOverflowError</code> caused by circular references.

<b>Database Schema Management</b>
- Column constraints (<code>nullable</code>, <code>length</code>) must be explicitly specified with <code>@Column</code>.
- The production <code>ddl-auto</code> configuration must be set to <code>validate</code> or <code>none</code>.
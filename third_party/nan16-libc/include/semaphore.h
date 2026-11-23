#ifndef _SEMAPHORE_H
#define _SEMAPHORE_H
typedef struct { int v; } sem_t;
int sem_init(sem_t *, int, unsigned);
int sem_wait(sem_t *);
int sem_post(sem_t *);
int sem_destroy(sem_t *);
#endif

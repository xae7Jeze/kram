/*
 * pfmailq - prints postfix mailqueues
 * in multiinstance setups
 *
 * Author: github.com/xae7Jeze
 *
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <ctype.h>
#include <sys/wait.h>
#include <pwd.h>
#include <sys/types.h>
#include <grp.h>

#define PATH "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
#define PM "postmulti"
#define U "postfix"
#define BL 4096
#define LL 100

extern char **environ;

int run_proc(char *arg[], int (*fd)[])
{
  pid_t pid;
  pid=fork();
  if(pid == -1){
    fprintf(stderr,"%s: fork failed\n","run_proc");
    return(-1);
  }
  if(pid > 0)
    return pid;
  while ((dup2((*fd)[1], STDOUT_FILENO) == -1) && (errno == EINTR)) {}
  close((*fd)[0]);
  close((*fd)[1]);
  execvp(arg[0], arg);
  return(-1);
}

int drop_priv(const char *u)
{
  struct passwd *pw;
  pw=getpwnam(u);
  if(pw == NULL || pw->pw_uid == 0)
    return(-1);
  if(setgid(pw->pw_gid) == -1)
    return(-1);
  if(initgroups(u, pw->pw_gid) == -1)
    return(-1);
  if(setuid(pw->pw_uid) == -1)
    return(-1);
  return(pw->pw_uid); 
}


int main(int argc, char *argv[])
{
  char *arg[10] = {NULL};
  char buffer[BL];
  char list[LL][BL];
  int fd1[2];
  int fd2[2];
  FILE *INPUT;
  int err;
  /* Drop privileges */
  if((err=drop_priv(U)) < 1){
    fprintf(stderr,"%s: drop privileges failed: %s (%d)\n",argv[0],strerror(errno),err);
    return(1);
  }

  /* cleanup environment */
  environ = NULL;
  setenv("PATH",PATH,1);
  
  int i,j=0;
  for(i=0;i<100;i++)
    memset(list[i],'\0',sizeof(list[i]));
  if (pipe(fd1) == -1) {
    fprintf(stderr,"%s: pipe failed\n",argv[0]);
    return(1);
  }
  arg[0] = PM;
  arg[1] = "-l";
  arg[2] = NULL;
  if(run_proc(arg,&fd1) == -1){
    fprintf(stderr,"%s: runproc '%s %s' failed: %s\n",argv[0],arg[0], arg[1],strerror(errno));
    close(fd1[0]);
    close(fd1[1]);
    return 1;
  }
  close(fd1[1]);
  INPUT=fdopen(fd1[0],"r");
  for(j = 0; j < LL && fgets(buffer, sizeof(buffer),INPUT) != NULL; j++) {
    for(i=0;i < BL - 1;i++){
      if(isspace(buffer[i]))
        break;
      list[j][i] = buffer[i];
    }
    list[j][i]='\0';
  }
  if(ferror(INPUT)){
    fprintf(stderr,"%s: read failed\n",argv[0]);
    clearerr(INPUT);
    wait(0);
    return(1);
  }
  fclose(INPUT);
  close(fd1[0]);
  for(j--;j >= 0;j--){
    arg[1]="-i";
    arg[2]=list[j];
    arg[3]="-x";
    arg[4]="postqueue";
    arg[5]="-p";
    arg[6] = NULL;
    if (pipe(fd2) == -1) {
      fprintf(stderr,"%s: pipe failed\n",argv[0]);
      return(1);
    }
    if(run_proc(arg,&fd1) == -1){
      fprintf(stderr,"%s: runproc '%s %s %s %s' failed\n",arg[0], arg[1], arg[2], arg[3], arg[4]);
      close(fd2[0]);
      close(fd2[1]);
      return 1;
    }
    close(fd2[1]);
    INPUT=fdopen(fd2[0],"r");
    if(*(arg[2] + 1) == '\0')
      strncpy(arg[2],"DEFAULT",BL-1);
    printf("%s/MailQueue\n", arg[2]);
    for(i = 0; arg[2][i] != '\0'; i++)
      fputc('=' ,stdout);
    printf ("==========\n\n");
    while (fgets(buffer, sizeof(buffer),INPUT) != NULL)
      printf("%s",buffer);
    if(ferror(INPUT)){
      fprintf(stderr,"%s: read failed\n",argv[0]);
      clearerr(INPUT);
      wait(0);
      return(1);
    }
    fclose(INPUT);
    close(fd2[0]);
  printf ("\n");
  }
  wait(0);
  return(0);
}

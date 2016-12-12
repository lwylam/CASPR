#define NANO_ID 4
#define FEEDBACK_PWM_MIN 504
#define FEEDBACK_PWM_MAX 1509
#define FEEDBACK_PWM_MIDDLE ( (FEEDBACK_PWM_MAX + FEEDBACK_PWM_MIN) / 2 )
#define COMMAND_PWM_MIN 491
#define COMMAND_PWM_MAX 1495
#define COMMAND_PWM_RANGE (COMMAND_PWM_MAX - COMMAND_PWM_MIN)

#define CLOCKWISE_PWM_MIN 2094
#define CLOCKWISE_PWM_MAX 2194
#define CLOCKWISE_SPEED_MIN 130
#define CLOCKWISE_SPEED_MAX 283
#define ANTICLOCKWISE_PWM_MIN 1891
#define ANTICLOCKWISE_PWM_MAX 1800
#define ANTICLOCKWISE_SPEED_MIN -133
#define ANTICLOCKWISE_SPEED_MAX -281
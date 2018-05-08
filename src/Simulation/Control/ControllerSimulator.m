% The simulator to run a control simulation
%
% Author        : Darwin LAU
% Created       : 2016
% Description    :
%   The control problem aims to solve for the cable forces in order to
%   track a reference trajectory in joint space. The controller algorithm
%   (ControllerBase object) is specified for the simulator. 
classdef ControllerSimulator < DynamicsSimulator
    properties (SetAccess = protected)
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % results
        compTime            % computational time for each time step
        refTrajectory       % The reference trajectory
        ctrl_trajectory     % The trajectory containing state variables used in the control command update
        ob_trajectory       % The observer trajectory containing estimated variables (state and/or disturbance)
        ctrl_fk_trajectory  % The forward kinematics (used with controller) trajectory containing estimated state variables (probably will only be used in debugging)
        ob_fk_trajectory    % The forward kinematics (used with observer) trajectory containing estimated state variables (probably will only be used in debugging)
        stiffness           % The stiffness matrices of the CDPR along the whole trajectory
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % simulator components
        fdSolver            % The forward dynamics solver
        fkSolver            % the forward kinematics solver, optional to use
        controller          % The controller for the system
        observer            % The disturbance observer for the system (if applicable)
        uncertainties       % A list of uncertainties
        true_model          % The true model for the system
        
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % simulator configurations
        simopt              % a ControllerSimulatorOptions object with all related options
        FK_solver_available % if true an FK solver is passed to the simulator
        observer_available  % if true an observer is passed to the simulator
        sim_vec_length      % total number of points run in simulation
        ctrl_vec_length     % total number of points run in command update
        ob_vec_length       % total number of points run in observer
                            
                            
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % intermediate variables (SHOULD BE UPDATED in corresponding cycles)
        % trajectory management
        sim_counter         % counts the number of points run in simulation
        ctrl_counter        % counts the number of points run in command update
        ob_counter          % counts the number of points run in observer
        % component communications
        % reference trajectory related
        q_ref               % the current reference point
        q_dot_ref           % the current reference velocity
        q_ddot_ref          % the current refernece acceleration
        % uncertainty related
        w_ext               % external wrench currently used to store disturbances
        w_ext_est           % the estimated external wrench
        q_ddot_ext          % external wrench currently used to store disturbances
        q_ddot_ext_est      % the equivalent acceleration of the estimated external wrench
        % controller related
        f_cmd               % force command in the current control cycle
        % FK related
        l                   % current cable lengths vector
        l_fk_prev_ctrl      % previous cable lengths vector for FK in controller
        q_fk_prev_ctrl      % previous joint pose for FK in controller
        q_d_fk_prev_ctrl    % previous joint velocity for FK in controller
        l_fk_prev_ob        % previous cable lengths vector for FK in observer
        q_fk_prev_ob        % previous joint pose for FK in observer
        q_d_fk_prev_ob      % previous joint velocity for FK in observer
        % FK related - relative encoder
        l_0_env             % initial cabel lengths in the environment (used to generate relative lengths when relative encoder is used)
        l_0_ctrl            % initial cabel lengths in the environment (used to restore the absolute lengths when relative encoder is used)
    
        rounding_error_guard % used to cut the effect of rounding error
        controlForces       % controlling forces including cable forces and active joint torques
        
    end

    methods
        % The control simulator constructor
        function ctrl_sim = ControllerSimulator(model, controller, fd_solver, fk_solver, uncertainties, true_model, observer, simopt)
            % the first 3 inputs will build a most basic controller
            % simulator, hence they should be valid
            ctrl_sim@DynamicsSimulator(model);
            ctrl_sim.model = model;
            ctrl_sim.controller = controller;
            ctrl_sim.fdSolver = fd_solver;
            
            % the rest inputs can be considered optional
            % fk_solver input
            if (isa(fk_solver, 'FKAnalysisBase'))
                ctrl_sim.fkSolver               =   fk_solver;
                ctrl_sim.FK_solver_available    =   true;
            else
                ctrl_sim.fkSolver               =   [];
                ctrl_sim.FK_solver_available    =   false;
            end
            % uncertainties input
            if (length(uncertainties) >= 1)
                ctrl_sim.uncertainties = {};
                for i = 1:length(uncertainties)
                    ctrl_sim.uncertainties = {};
                    if(isa(uncertainties{i},'ConstructorUncertaintyBase'))
                        if (isa(true_model, 'SystemModel'))
                            uncertainties{i}.applyConstructorUncertainty(true_model);
                        end
                    end
                    if(isa(uncertainties{i},'ConstructorUncertaintyBase') || isa(uncertainties{i},'PreUpdateUncertaintyBase') || isa(uncertainties{i},'PostUpdateUncertaintyBase'))
                        ctrl_sim.uncertainties = {ctrl_sim.uncertainties; uncertainties{i}};
                    end
                end
            end
            % true model input
            if (isa(true_model, 'SystemModel'))
                ctrl_sim.true_model     =   true_model;
            else
                ctrl_sim.true_model     =   model;
            end
            % disturbance observer input
            if (isa(observer, 'ObserverBase'))
                ctrl_sim.observer               =   observer;
                ctrl_sim.observer_available     =   true;
            else
                ctrl_sim.observer               =   [];
                ctrl_sim.observer_available     =   false;
            end
            % simulator options input
            if (isa(simopt, 'ControllerSimulatorOptions'))
                ctrl_sim.simopt     =   simopt;
            else
                ctrl_sim.simopt     =   ControllerSimulatorOptions();
            end
            ctrl_sim.rounding_error_guard = 1e-5;
            ctrl_sim.optionConsistencyCheck();
        end
        
        % simulator option consistency check
        function optionConsistencyCheck(obj)
            % 1. simulation frequency ratio input
            obj.simopt.sim_freq_ratio = max(1, obj.simopt.sim_freq_ratio);
            % 2. observer frequency ratio input
            obj.simopt.ob_freq_ratio = max(1, obj.simopt.ob_freq_ratio);
            obj.simopt.ob_freq_ratio = min(obj.simopt.ob_freq_ratio, obj.simopt.sim_freq_ratio);
            % 3. encoder option input (no potential inconsistency)
            % 4. FK solver toggle
            if (~obj.FK_solver_available)
                obj.simopt.enable_FK_solver     =   false;
            end
            % 5. FK debugging
            if (~obj.simopt.enable_FK_solver)
                obj.simopt.forward_kinematics_debugging = false;
            end
            % 6. observer toggle
            if (~obj.observer_available)
                obj.simopt.enable_observer      =   false;
            end
            % 6. other consistency check
            if (~obj.simopt.enable_observer)
                if (obj.simopt.use_ob_state_estimation || obj.simopt.use_ob_disturbance_estimation)
                    CASPR_log.Warn(sprintf('Observer estimation cannot be used without enabling or giving an observer in the simulator. All observer usage will be disabled.'));
                    obj.simopt.use_ob_state_estimation        =   false;
                    obj.simopt.use_ob_disturbance_estimation  =   false;
                end
            end
            if (~obj.simopt.enable_FK_solver)
                if (obj.simopt.use_FK_in_controller || obj.simopt.use_FK_in_observer)
                    CASPR_log.Warn(sprintf('FK pose estimation cannot be used without enabling or giving an FK solver in the simulator. All FK usage will be disabled.'));
                    obj.simopt.use_FK_in_controller	=   false;
                    obj.simopt.use_FK_in_observer	=   false;
                end
            end
            if (obj.simopt.use_ob_state_estimation && obj.simopt.use_FK_in_controller)
                CASPR_log.Warn(sprintf('Observer state and FK state cannot be used in the controller at the same time, only one of them should be enabled. Will enable FK use only'));
                obj.simopt.use_ob_state_estimation	=   false;
                obj.simopt.use_FK_in_controller     =   false;
            end
        end

        % Implementation of the run function. Converts the dynamics
        % information into a controller
        function run(obj, ref_trajectory, q0, q0_dot, q0_ddot)
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % SIMULATION FREQUENCY SETTINGS
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % starting time and ending time
            t0 = ref_trajectory.timeVector(1);
            tf = ref_trajectory.timeVector(length(ref_trajectory.timeVector));
            % controller is assumed to run with the same frequency defined
            % in the reference trajectory
            obj.ctrl_vec_length	=   length(ref_trajectory.timeVector);
            obj.sim_vec_length	=   obj.simopt.sim_freq_ratio*obj.ctrl_vec_length;
            obj.ob_vec_length   =   obj.simopt.ob_freq_ratio*obj.ctrl_vec_length;
            ctrl_delta_t        =   (tf - t0)/(obj.ctrl_vec_length - 1);
            ob_delta_t          =   (tf - t0)/(obj.ob_vec_length - 1);
            % initialize the computational time record variable
            obj.compTime        =   zeros(obj.ctrl_vec_length, 1);
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % DECLARE SIMULATION TRAJECTORIES
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            obj.refTrajectory = ref_trajectory;
            % controller related variables
            obj.ctrl_trajectory             =   JointTrajectory;
            obj.ctrl_trajectory.timeVector  =   obj.refTrajectory.timeVector;
            obj.controlForces              	=   cell(1, length(obj.ctrl_trajectory.timeVector));
            obj.ctrl_trajectory.q           =   cell(1, length(obj.ctrl_trajectory.timeVector));
            obj.ctrl_trajectory.q_dot       =   cell(1, length(obj.ctrl_trajectory.timeVector));
            obj.ctrl_trajectory.q_ddot      =   cell(1, length(obj.ctrl_trajectory.timeVector));
            % obj.trajectory and objtimeVector represent the actual world, or the
            % finer resolution simulation in our case
            % simulation related variables
            obj.timeVector              =   t0:(tf - t0)/(obj.sim_vec_length - 1):tf;
            obj.trajectory              =   JointTrajectory;
            obj.trajectory.timeVector   =   obj.timeVector;
            obj.trajectory.q            =   cell(1, length(obj.trajectory.timeVector));
            obj.trajectory.q_dot        =   cell(1, length(obj.trajectory.timeVector));
            obj.trajectory.q_ddot       =   cell(1, length(obj.trajectory.timeVector));
            if (obj.simopt.is_operational_space_control)
                % task space related variables
                obj.trajectory_op               =   OperationalTrajectory;
                obj.trajectory_op.timeVector    =   obj.timeVector;
                obj.trajectory_op.y             =   cell(1, length(obj.trajectory_op.timeVector));
                obj.trajectory_op.y_dot         =   cell(1, length(obj.trajectory_op.timeVector));
                obj.trajectory_op.y_ddot        =   cell(1, length(obj.trajectory_op.timeVector));
            end
            % disturbance observer related variables
            obj.ob_trajectory = ObserverTrajectory;
            obj.ob_trajectory.timeVector = t0:(tf - t0)/(obj.ob_vec_length - 1):tf;
            obj.ob_trajectory.q_est             =   cell(1, length(obj.ob_trajectory.timeVector));
            obj.ob_trajectory.q_dot_est         =   cell(1, length(obj.ob_trajectory.timeVector));
            obj.ob_trajectory.w_ext             =   cell(1, length(obj.ob_trajectory.timeVector));
            obj.ob_trajectory.w_ext_est         =   cell(1, length(obj.ob_trajectory.timeVector));
            obj.ob_trajectory.q_ddot_ext        =   cell(1, length(obj.ob_trajectory.timeVector));
            obj.ob_trajectory.q_ddot_ext_est    =   cell(1, length(obj.ob_trajectory.timeVector));
            % optional trajectory data (for FK debugging)
            if (obj.simopt.forward_kinematics_debugging)
                % forward kinematics solver (used with the controller) related variables
                obj.ctrl_fk_trajectory              =   JointTrajectory;
                obj.ctrl_fk_trajectory.timeVector   =   obj.ctrl_trajectory.timeVector;
                obj.ctrl_fk_trajectory.q            =   cell(1, length(obj.ctrl_fk_trajectory.timeVector));
                obj.ctrl_fk_trajectory.q_dot        =   cell(1, length(obj.ctrl_fk_trajectory.timeVector));
                obj.ctrl_fk_trajectory.q_ddot       =   cell(1, length(obj.ctrl_fk_trajectory.timeVector));
                % forward kinematics solver (used with the controller) related variables
                obj.ob_fk_trajectory                =   JointTrajectory;
                obj.ob_fk_trajectory.timeVector     =   obj.ob_trajectory.timeVector;
                obj.ob_fk_trajectory.q              =   cell(1, length(obj.ob_fk_trajectory.timeVector));
                obj.ob_fk_trajectory.q_dot          =   cell(1, length(obj.ob_fk_trajectory.timeVector));
                obj.ob_fk_trajectory.q_ddot         =   cell(1, length(obj.ob_fk_trajectory.timeVector));
            end
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % SIMULATOR INITIALIZATIONS
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % initialize the trajectories
            obj.trajectory.q{1}                 =   q0;
            obj.trajectory.q_dot{1}             =   q0_dot;
            obj.trajectory.q_ddot{1}            =   q0_ddot;
            obj.ctrl_trajectory.q{1}            =   q0;
            obj.ctrl_trajectory.q_dot{1}        =   q0_dot;
            obj.ctrl_trajectory.q_ddot{1}       =   q0_ddot;
            obj.ob_trajectory.q{1}              =   q0;
            obj.ob_trajectory.q_dot{1}          =   q0_dot;
            obj.ob_trajectory.q_ddot_ext_est{1}	=   zeros(obj.model.numDofs, 1);
            if (obj.simopt.forward_kinematics_debugging)
                obj.ctrl_fk_trajectory.q{1}         =   q0;
                obj.ctrl_fk_trajectory.q_dot{1}     =   q0_dot;
                obj.ctrl_fk_trajectory.q_ddot{1}    =   q0_ddot;
                obj.ob_fk_trajectory.q{1}           =   q0;
                obj.ob_fk_trajectory.q_dot{1}       =   q0_dot;
                obj.ob_fk_trajectory.q_ddot{1}      =   q0_ddot;
            end
            % apply initial pose uncertainties, if applicable
            % initial pose error will only affect the simulation (or FD)
            % process, it will not affect what the controller thinks of the
            % robot status (will not change ctrl_trajectory), in other
            % words if something goes wrong, the simulation will tell a
            % difference but the controll will still think everything's ok
            for i = 1:length(obj.uncertainties)
                if(isa(obj.uncertainties{i},'InitialPoseUncertaintyBase'))
                    [obj.trajectory.q{1}, obj.trajectory.q_dot{1}] = obj.uncertainties{i}.applyInitialOffset(q0,q0_dot);
                    obj.trajectory.q_ddot{1} = q0_ddot;
                end
            end
            
            % initialize counters
            obj.sim_counter     =   1;
            obj.ctrl_counter    =   1;
            obj.ob_counter      =   1;
            
            % initialize the FK and encoder related variables
            % update all models first
            obj.true_model.update(obj.trajectory.q{1}, obj.trajectory.q_dot{1}, zeros(obj.model.numDofs, 1), zeros(obj.model.numDofs,1));
            obj.model.update(obj.ctrl_trajectory.q{1}, obj.ctrl_trajectory.q_dot{1}, zeros(obj.model.numDofs, 1), zeros(obj.model.numDofs,1));
            % initialize cable lengths according to the type of encoder
            % used
            if (obj.simopt.use_absolute_encoder)
                % in case absolute encoder used, no need to keep initial
                % lengths
                obj.l_0_ctrl    =   [];
                obj.l_0_env     =   [];
                obj.l           =   obj.true_model.cableLengths;
            else
                % in case relative encoder used, need to keep the initial
                % lengths, so that relative length can be calculated later
                obj.l_0_ctrl    =   obj.model.cableLengths;
                obj.l_0_env     =   obj.true_model.cableLengths;
                obj.l           =   obj.model.cableLengths;
            end
            % initialize FK slover related variables (if needed)
            if (obj.simopt.enable_FK_solver)
                obj.l_fk_prev_ctrl      =   obj.l;
                obj.q_fk_prev_ctrl      =   obj.ctrl_trajectory.q{1};
                obj.q_d_fk_prev_ctrl    =   obj.ctrl_trajectory.q_dot{1};
                obj.l_fk_prev_ob        =   obj.l;
                obj.q_fk_prev_ob        =   obj.ob_trajectory.q{1};
                obj.q_d_fk_prev_ob      =   obj.ob_trajectory.q_dot{1};
            else
                obj.l_fk_prev_ctrl      =   [];
                obj.q_fk_prev_ctrl      =   [];
                obj.q_d_fk_prev_ctrl    =   [];
                obj.l_fk_prev_ob        =   [];
                obj.q_fk_prev_ob        =   [];
                obj.q_d_fk_prev_ob      =   [];
            end
            
            % initialize communication variables
            % force command is always used since the controller is always a
            % component in the controller simulator
            obj.f_cmd           =   zeros(obj.model.numCables,1);
            % l will always be updated in case FK exists as a component
            obj.l               =   zeros(obj.model.numCables,1);
            % actual disturbances will be updated if the corresponding
            % disturbance is given as input. otherwise they will remain 0
            obj.w_ext           =   zeros(obj.model.numDofs,1);
            obj.q_ddot_ext      =   zeros(obj.model.numDofs,1);
            % estimated disturbances will be updated if disturbance
            % observer exists as a component. otherwies they will remain 0
            obj.w_ext_est       =   zeros(obj.model.numDofs,1);
            obj.q_ddot_ext_est  =   zeros(obj.model.numDofs,1);
            
            % update length feedback
            obj.cableLengthFeedbackUpdate();
            % post-update uncertainty update
            obj.postUpdateUncertainyUpdate(0);
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % START THE MAIN LOOP
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            first_cycle = true;
            for t = 1:length(obj.timeVector)
                if (~obj.simopt.is_silent_mode)
                    CASPR_log.Info(sprintf('Time : %f', obj.timeVector(t)));
                    CASPR_log.Info(sprintf('Completion Percentage: %3.2f%%',100*t/length(obj.timeVector)));
                end
                                
                % extract current time to make component update decisions
                current_time = obj.timeVector(t);
                
                % update model
                obj.true_model.update(obj.trajectory.q{obj.sim_counter}, obj.trajectory.q_dot{obj.sim_counter}, zeros(obj.model.numDofs, 1), zeros(obj.model.numDofs,1));
                
                % control command (and FK, if applicable) update
                if (first_cycle)
                    obj.ctrl_counter = 0;
                end
                if (current_time >= obj.ctrl_trajectory.timeVector(obj.ctrl_counter + 1) - obj.rounding_error_guard)
                    % update the counter
                    obj.ctrl_counter = obj.ctrl_counter + 1;
                    % update time profile
                    obj.ctrl_trajectory.timeVector(obj.ctrl_counter) = current_time;
                    % update control command and save the corresponding
                    % data
                    obj.controlCommandUpdate(ctrl_delta_t);
                end
                
                % observer update (the observer should spit out the equivalent acceleration)
                if (first_cycle)
                    % update the counter
                    obj.ob_counter = 0;
                end
                if (current_time >= obj.ob_trajectory.timeVector(obj.ob_counter + 1) - obj.rounding_error_guard)
                    if (obj.simopt.enable_observer)
                        % update the counter
                        obj.ob_counter = obj.ob_counter + 1;
                        % update time profile
                        obj.ob_trajectory.timeVector(obj.ob_counter) = current_time;
                        % update the observer estimation
                        obj.observerEstimationUpdate(ob_delta_t);
                    end
                end
                
                
                % FD update
                if (current_time < tf)
                    % pre-update uncertainty update
                    skip_FD     =   obj.preUpdateUncertainyUpdate(current_time);
                    % do forward dynamic update
                    obj.forwardDynamicUpdate(skip_FD);
                    % update length feedback
                    obj.cableLengthFeedbackUpdate();
                    % post-update uncertainty update
                    obj.postUpdateUncertainyUpdate(current_time);
                else
                    if (t ~= obj.sim_counter)
                        CASPR_log.Error(sprintf('Something does not add up in FD update.'));
                    end
                end
                
                first_cycle = false;
            end
        end
        
        % function to do cable length feedback update
        function cableLengthFeedbackUpdate(obj)
            if (obj.simopt.use_absolute_encoder)
                % if absolute encoder used, get cable lengths directly from the environment
                obj.l	=   obj.true_model.cableLengths;
            else
                % if relative encoder used, get relative cable
                % lengths from the environment and then convert into absolute lengths
                obj.l	=   obj.l_0_ctrl + obj.true_model.cableLengths - obj.l_0_env;
            end
        end
        
        % function to do control command update
        function controlCommandUpdate(obj, ctrl_delta_t)
            tic;
            % derive the feedback information for the controller
            obj.controllerFeedbackUpdate(ctrl_delta_t);


            % get the disturbance estimation
            if (obj.simopt.use_ob_disturbance_estimation)
                obj.q_ddot_ext_est  =   obj.ob_trajectory.q_ddot_ext_est{obj.ob_counter};
            else
                obj.q_ddot_ext_est  =   zeros(obj.model.numDofs,1);
            end

            % run control command update
            if (obj.simopt.is_operational_space_control)
                [obj.f_cmd, ~, ~]  = ...
                    obj.controller.execute(obj.ctrl_trajectory.q{obj.ctrl_counter}, obj.ctrl_trajectory.q_dot{obj.ctrl_counter}, zeros(obj.model.numDofs,1), obj.refTrajectory.y{obj.ctrl_counter}, obj.refTrajectory.y_dot{obj.ctrl_counter}, obj.refTrajectory.y_ddot{obj.ctrl_counter}, obj.q_ddot_ext_est, obj.ctrl_counter);
            else
                [obj.f_cmd, ~, ~]  = ...
                    obj.controller.execute(obj.ctrl_trajectory.q{obj.ctrl_counter}, obj.ctrl_trajectory.q_dot{obj.ctrl_counter}, zeros(obj.model.numDofs,1), obj.refTrajectory.q{obj.ctrl_counter}, obj.refTrajectory.q_dot{obj.ctrl_counter}, obj.refTrajectory.q_ddot{obj.ctrl_counter}, obj.q_ddot_ext_est, obj.ctrl_counter);
            end
            obj.compTime(obj.ctrl_counter)              =   toc;
            % save the data
            obj.controlForces{obj.ctrl_counter}        	=   obj.f_cmd;
            obj.cableForces{obj.ctrl_counter}        	=   obj.f_cmd(1:obj.model.numCables);
        end
        
        % update state feedback for controller and save the data into
        % obj.ctrl_trajectory
        function controllerFeedbackUpdate(obj, ctrl_delta_t)
            if (obj.simopt.use_FK_in_controller)
                % if FK is used:
                % 1. use q_fk_prev, q_d_fk_prev and the l_fk_prev to generate new q and q_dot
                % 2. update q_fk_prev, q_d_fk_prev and the l_fk_prev
                % 3. also update ctrl_trajectory
                [obj.q_fk_prev_ctrl, obj.q_d_fk_prev_ctrl, ~] = ...
                    obj.fkSolver.compute(obj.l, obj.l_fk_prev_ctrl, obj.model.cableModel.cableIndicesActive, obj.q_fk_prev_ctrl, obj.q_d_fk_prev_ctrl, ctrl_delta_t);
                obj.l_fk_prev_ctrl = obj.l;
                obj.ctrl_trajectory.q{obj.ctrl_counter}     =   obj.q_fk_prev_ctrl;
                obj.ctrl_trajectory.q_dot{obj.ctrl_counter} =   obj.q_d_fk_prev_ctrl;
            elseif (obj.simopt.use_ob_state_estimation)
                % in this case the latest estimated state will be used in the controller
                obj.ctrl_trajectory.q{obj.ctrl_counter}     =   obj.ob_trajectory.q{obj.ob_counter};
                obj.ctrl_trajectory.q_dot{obj.ctrl_counter} =   obj.ob_trajectory.q_dot{obj.ob_counter};
            else
                % if FK is not used:
                % directly take joint space variables from
                % environment
                obj.ctrl_trajectory.q{obj.ctrl_counter}     =   obj.trajectory.q{obj.sim_counter};
                obj.ctrl_trajectory.q_dot{obj.ctrl_counter} =   obj.trajectory.q_dot{obj.sim_counter};
            end
            
            % save FK trajectory if required
            if (obj.simopt.forward_kinematics_debugging)
                if (~obj.simopt.use_FK_in_controller)
                    % do FK update iff it has not been done for the
                    % controller yet
                    [obj.q_fk_prev_ctrl, obj.q_d_fk_prev_ctrl, ~] = ...
                        obj.fkSolver.compute(obj.l, obj.l_fk_prev_ctrl, obj.model.cableModel.cableIndicesActive, obj.q_fk_prev_ctrl, obj.q_d_fk_prev_ctrl, ctrl_delta_t);
                end
                obj.l_fk_prev_ctrl = obj.l;
                obj.ctrl_fk_trajectory.q{obj.ctrl_counter}     =   obj.q_fk_prev_ctrl;
                obj.ctrl_fk_trajectory.q_dot{obj.ctrl_counter} =   obj.q_d_fk_prev_ctrl;
            end
        end
        
        % function to do observer estimation update
        function observerEstimationUpdate(obj, ob_delta_t)
            % derive the feedback information for the observer
            obj.observerFeedbackUpdate(ob_delta_t);
            
            % update the observer estimation
            [q_est, q_dot_est, q_ddot_disturbance_est, wrench_disturbance_est]    =   ...
                obj.observer.executeFunction(obj.ob_trajectory.q{obj.ob_counter}, obj.ob_trajectory.q_dot{obj.ob_counter}, obj.controlForces{obj.ctrl_counter}, zeros(obj.model.numDofs, 1), obj.ob_counter);
            obj.w_ext_est           =   wrench_disturbance_est;
            obj.q_ddot_ext_est      =   q_ddot_disturbance_est;
            
            % save the data
            obj.ob_trajectory.q_est{obj.ob_counter}             =   q_est;
            obj.ob_trajectory.q_dot_est{obj.ob_counter}         =   q_dot_est;
            obj.ob_trajectory.w_ext{obj.ob_counter}             =   -obj.w_ext;
            obj.ob_trajectory.w_ext_est{obj.ob_counter}         =   wrench_disturbance_est;
            obj.ob_trajectory.q_ddot_ext{obj.ob_counter}        =   -obj.q_ddot_ext;
            obj.ob_trajectory.q_ddot_ext_est{obj.ob_counter}    =   q_ddot_disturbance_est;
        end
        
        % update state feedback for observer and save the data into
        % obj.ob_trajectory
        function observerFeedbackUpdate(obj, ob_delta_t)
            if (obj.simopt.use_FK_in_observer)
                % if FK is used:
                % 1. use q_fk_prev, q_d_fk_prev and the l_fk_prev to generate new q and q_dot
                % 2. update q_fk_prev, q_d_fk_prev and the l_fk_prev
                % 3. also update ctrl_trajectory
                [obj.q_fk_prev_ob, obj.q_d_fk_prev_ob, ~] = ...
                    obj.fkSolver.compute(obj.l, obj.l_fk_prev_ob, obj.model.cableModel.cableIndicesActive, obj.q_fk_prev_ob, obj.q_d_fk_prev_ob, ob_delta_t);
                obj.l_fk_prev_ob = obj.l;
                obj.ob_trajectory.q{obj.ob_counter}     =   obj.q_fk_prev_ob;
                obj.ob_trajectory.q_dot{obj.ob_counter} =   obj.q_d_fk_prev_ob;
            else
                % if FK is not used:
                % directly take joint space variables from
                % environment
                obj.ob_trajectory.q{obj.ob_counter}     =   obj.trajectory.q{obj.sim_counter};
                obj.ob_trajectory.q_dot{obj.ob_counter} =   obj.trajectory.q_dot{obj.sim_counter};
            end

            % save FK trajectory if required
            if (obj.simopt.forward_kinematics_debugging)
                if (~obj.simopt.use_FK_in_observer)
                    % do FK update iff it has not been done for the
                    % controller yet
                    [obj.q_fk_prev_ob, obj.q_d_fk_prev_ob, ~] = ...
                        obj.fkSolver.compute(obj.l, obj.l_fk_prev_ob, obj.model.cableModel.cableIndicesActive, obj.q_fk_prev_ob, obj.q_d_fk_prev_ob, ob_delta_t);
                end
                obj.l_fk_prev_ob = obj.l;
                obj.ob_fk_trajectory.q{obj.ob_counter}     =   obj.q_fk_prev_ob;
                obj.ob_fk_trajectory.q_dot{obj.ob_counter} =   obj.q_d_fk_prev_ob;
            end
        end
        
        % function to do forward dynamic update
        function forwardDynamicUpdate(obj, skip_FD)
            if (skip_FD)
                % update sim_trajectory with current step data, no
                % need to run FD
                obj.trajectory.q{obj.sim_counter + 1}       =   obj.trajectory.q{obj.sim_counter};
%                 obj.trajectory.q_dot{obj.sim_counter + 1}	=   obj.trajectory.q_dot{obj.sim_counter};
%                 obj.trajectory.q_ddot{obj.sim_counter + 1}	=   obj.trajectory.q_ddot{obj.sim_counter};
                obj.trajectory.q_dot{obj.sim_counter + 1}	=   0*obj.trajectory.q_dot{obj.sim_counter};
                obj.trajectory.q_ddot{obj.sim_counter + 1}	=   0*obj.trajectory.q_ddot{obj.sim_counter};
                % record the stiffness when the system is not in the
                % compiled mode
                if (obj.model.modelMode ~= ModelModeType.COMPILED)
                    obj.stiffness{obj.sim_counter + 1}     	 =   obj.model.K;
                end
            else
                % update sim_trajectory with new state from FD
                % algorithm                
                [obj.trajectory.q{obj.sim_counter + 1}, obj.trajectory.q_dot{obj.sim_counter + 1}, obj.trajectory.q_ddot{obj.sim_counter + 1}, obj.true_model] = ...
                    obj.fdSolver.compute(obj.trajectory.q{obj.sim_counter}, obj.trajectory.q_dot{obj.sim_counter}, obj.controlForces{obj.ctrl_counter}, obj.true_model.cableModel.cableIndicesActive, obj.w_ext, obj.timeVector(obj.sim_counter + 1) - obj.timeVector(obj.sim_counter), obj.true_model);
                obj.trajectory.q_ddot{obj.sim_counter + 1}	=   obj.trajectory.q_ddot{obj.sim_counter};
                if (obj.simopt.is_operational_space_control)
                    obj.trajectory_op.y{obj.sim_counter + 1}        =   obj.true_model.y;
                    obj.trajectory_op.y_dot{obj.sim_counter + 1}    =   obj.true_model.y_dot;
                    obj.trajectory_op.y_ddot{obj.sim_counter + 1}   =   obj.true_model.y_ddot;
                end
                % record the stiffness when the system is not in the
                % compiled mode
                if (obj.model.modelMode ~= ModelModeType.COMPILED)
                    obj.stiffness{obj.sim_counter + 1}     	 =   obj.model.K;
                end
            end
            obj.sim_counter = obj.sim_counter + 1;
        end
        
        % function to do pre-update uncertainty update
        function [skip_FD]  =   preUpdateUncertainyUpdate(obj, current_time)
            % pre-update uncertainty update
            skip_FD = false;
            for i = 1:length(obj.uncertainties)
                if(isa(obj.uncertainties{i},'ExternalWrenchUncertaintyBase'))
                    [obj.w_ext] = obj.uncertainties{i}.applyWrechDisturbance(current_time);
%                     obj.w_ext
                    obj.q_ddot_ext = obj.true_model.M\obj.w_ext;
                end
                if(isa(obj.uncertainties{i},'PoseLockUncertaintyBase'))
                    [skip_FD] = obj.uncertainties{i}.applyPoseLock(current_time);
                end
            end
        end
        
        % function to do post-update uncertainty update
        function postUpdateUncertainyUpdate(obj, current_time)
            % post-update uncertainty update
            for i = 1:length(obj.uncertainties)
                if(isa(obj.uncertainties{i},'NoiseUncertaintyBase'))
                    [noise_x, ~] = obj.uncertainties{i}.applyFeedbackNoise(current_time);
                    obj.l       =   obj.l + noise_x;
                end
            end
        end
                
        % Getters
        function controller = getController(obj)            
            controller = obj.controller;
        end
        
        % Setters
        function setController(obj, controller)
            CASPR_log.Assert(isa(controller, 'ControllerBase'), 'Input argument is not a valid controller.');
            obj.controller = controller;            
        end
        
        % Assign data to matlab workspace
        function [output_data]     =   extractData(obj)
            if (obj.simopt.is_operational_space_control)
                ref_timevec     =   obj.refTrajectory.timeVector';
                ref_y           =   cell2mat(obj.refTrajectory.y)';
                ref_y_dot      	=   cell2mat(obj.refTrajectory.y_dot)';
                ref_y_ddot     	=   cell2mat(obj.refTrajectory.y_ddot)';
                len_ref = min([ size(ref_timevec, 1), ...
                            size(ref_y, 1), ...
                            size(ref_y_dot, 1), ...
                            size(ref_y_ddot, 1)]);
                ref_timevec     =   ref_timevec(1:len_ref, :);
                ref_y           =   ref_y(1:len_ref, :);
                ref_y_dot       =   ref_y_dot(1:len_ref, :);
                ref_y_ddot      =   ref_y_ddot(1:len_ref, :);
                
                output_data.DataRefTime           	=   ref_timevec;
                output_data.DataRefPose             =   ref_y;
                output_data.DataRefVelocity         =   ref_y_dot;
                output_data.DataRefAcceleration 	=   ref_y_ddot;
            else
                ref_timevec     =   obj.refTrajectory.timeVector';
                ref_q           =   cell2mat(obj.refTrajectory.q)';
                ref_q_dot      	=   cell2mat(obj.refTrajectory.q_dot)';
                ref_q_ddot     	=   cell2mat(obj.refTrajectory.q_ddot)';
                len_ref = min([ size(ref_timevec, 1), ...
                            size(ref_q, 1), ...
                            size(ref_q_dot, 1), ...
                            size(ref_q_ddot, 1)]);
                ref_timevec     =   ref_timevec(1:len_ref, :);
                ref_q           =   ref_q(1:len_ref, :);
                ref_q_dot       =   ref_q_dot(1:len_ref, :);
                ref_q_ddot      =   ref_q_ddot(1:len_ref, :);
                
                output_data.DataRefTime                 =   ref_timevec;
                output_data.DataRefPose            =   ref_q;
                output_data.DataRefVelocity        =   ref_q_dot;
                output_data.DataRefAcceleration	=   ref_q_ddot;
            end
            % perform frequency analysis and output the data
            output_data.freqAnalysis.referenceTime       	=   output_data.DataRefTime;
            output_data.freqAnalysis.referencePose          =   output_data.DataRefPose;
            output_data.freqAnalysis.referenceVelocity      =   output_data.DataRefVelocity;
            output_data.freqAnalysis.referenceAcceleration  =   output_data.DataRefAcceleration;
            if (~isempty(output_data.freqAnalysis.referenceTime))
                [output_data.freqAnalysis.referencePoseFS1, output_data.freqAnalysis.referenceF1, output_data.freqAnalysis.referencePoseFS1Threshold, output_data.freqAnalysis.referencePoseFS1Summed]...
                    = fftAnalysis(output_data.freqAnalysis.referenceTime, output_data.freqAnalysis.referencePose, 0.9);
                [output_data.freqAnalysis.referenceVelocityFS1, ~, output_data.freqAnalysis.referenceVelocityFS1Threshold, output_data.freqAnalysis.referenceVelocityFS1Summed]...
                    = fftAnalysis(output_data.freqAnalysis.referenceTime, output_data.freqAnalysis.referenceVelocity, 0.9);
                [output_data.freqAnalysis.referenceAccelerationFS1, ~, output_data.freqAnalysis.referenceAccelerationFS1Threshold, output_data.freqAnalysis.referenceAccelerationFS1Summed]...
                    = fftAnalysis(output_data.freqAnalysis.referenceTime, output_data.freqAnalysis.referenceAcceleration, 0.9);
            end
            
            ctrl_timevec   	=   obj.ctrl_trajectory.timeVector';
            ctrl_q         	=   cell2mat(obj.ctrl_trajectory.q)';
            ctrl_q_dot     	=   cell2mat(obj.ctrl_trajectory.q_dot)';
            ctrl_f_cmd    	=   cell2mat(obj.controlForces)';
            len_ctrl = min([ size(ctrl_timevec, 1), ...
                        size(ctrl_q, 1), ...
                        size(ctrl_q_dot, 1), ...
                        size(ctrl_f_cmd, 1)]);
            ctrl_timevec     =   ctrl_timevec(1:len_ctrl, :);
            ctrl_q           =   ctrl_q(1:len_ctrl, :);
            ctrl_q_dot       =   ctrl_q_dot(1:len_ctrl, :);
            ctrl_f_cmd      =   ctrl_f_cmd(1:len_ctrl, :);
            
            output_data.DataCtrlTime            =   ctrl_timevec;
            output_data.DataCtrlJointPose       =   ctrl_q;
            output_data.DataCtrlJointVelocity  	=   ctrl_q_dot;
            output_data.DataCtrlForceCommands	=   ctrl_f_cmd;
            
            sim_timevec    	=   obj.trajectory.timeVector';
            sim_q         	=   cell2mat(obj.trajectory.q)';
            sim_q_dot     	=   cell2mat(obj.trajectory.q_dot)';
            len_sim = min([ size(sim_timevec, 1), ...
                        size(sim_q, 1), ...
                        size(sim_q_dot, 1)]);
            sim_timevec     =   sim_timevec(1:len_sim, :);
            sim_q           =   sim_q(1:len_sim, :);
            sim_q_dot       =   sim_q_dot(1:len_sim, :);
            
            output_data.DataSimTime           	=   sim_timevec;
            output_data.DataSimJointPose    	=   sim_q;
            output_data.DataSimJointVelocity	=   sim_q_dot;
            if (obj.simopt.is_operational_space_control)
                sim_timevec    	=   obj.trajectory_op.timeVector';
                sim_y         	=   cell2mat(obj.trajectory_op.y)';
                sim_y_dot     	=   cell2mat(obj.trajectory_op.y_dot)';
                len_sim = min([ size(sim_timevec, 1), ...
                            size(sim_y, 1), ...
                            size(sim_y_dot, 1)]);
                sim_y           =   sim_y(1:len_sim, :);
                sim_y_dot       =   sim_y_dot(1:len_sim, :);
                
                output_data.DataSimOpPose    	=   sim_y;
                output_data.DataSimOpVelocity	=   sim_y_dot;
            end
            
            ob_timevec   	=   obj.ob_trajectory.timeVector';
            ob_q_est       	=   cell2mat(obj.ob_trajectory.q_est)';
            ob_q_dot_est   	=   cell2mat(obj.ob_trajectory.q_dot_est)';
            ob_q         	=   cell2mat(obj.ob_trajectory.q)';
            ob_q_dot     	=   cell2mat(obj.ob_trajectory.q_dot)';
            ob_wd        	=   cell2mat(obj.ob_trajectory.w_ext)';
            ob_ad           =   cell2mat(obj.ob_trajectory.q_ddot_ext)';
            ob_wd_est      	=   cell2mat(obj.ob_trajectory.w_ext_est)';
            ob_ad_est     	=   cell2mat(obj.ob_trajectory.q_ddot_ext_est)';
            len_ob = min([ size(ob_timevec, 1), ...
                        size(ob_q_est, 1), ...
                        size(ob_q_dot_est, 1), ...
                        size(ob_q, 1), ...
                        size(ob_q_dot, 1), ...
                        size(ob_wd, 1), ...
                        size(ob_ad, 1), ...
                        size(ob_wd_est, 1), ...
                        size(ob_ad_est, 1)]);
            ob_timevec      =   ob_timevec(1:len_ob, :);
            ob_q_est      	=   ob_q_est(1:len_ob, :);
            ob_q_dot_est   	=   ob_q_dot_est(1:len_ob, :);
            ob_q            =   ob_q(1:len_ob, :);
            ob_q_dot        =   ob_q_dot(1:len_ob, :);
            ob_wd           =   ob_wd(1:len_ob, :);
            ob_ad           =   ob_ad(1:len_ob, :);
            ob_wd_est      	=   ob_wd_est(1:len_ob, :);
            ob_ad_est       =   ob_ad_est(1:len_ob, :);
            
            output_data.DataObTime                          =   ob_timevec;
            output_data.DataObJointPoseEst                  =   ob_q_est;
            output_data.DataObJointVelocityEst           	=   ob_q_dot_est;
            output_data.DataObJointPose                     =   ob_q;
            output_data.DataObJointVelocity                 =   ob_q_dot;
            output_data.DataObDisturbanceWrench           	=   ob_wd;
            output_data.DataObDisturbanceAcceleration     	=   ob_ad;
            output_data.DataObDisturbanceWrenchEst       	=   ob_wd_est;
            output_data.DataObDisturbanceAccelerationEst	=   ob_ad_est;
            % perform frequency analysis and output the data
            output_data.freqAnalysis.disturbanceTime       	=   output_data.DataObTime;
            output_data.freqAnalysis.disturbanceInAcc       =   output_data.DataObDisturbanceAcceleration;
            output_data.freqAnalysis.disturbanceEstInAcc    =   output_data.DataObDisturbanceAccelerationEst;
            if (~isempty(output_data.freqAnalysis.disturbanceTime))
                [output_data.freqAnalysis.disturbanceInAccFS1, output_data.freqAnalysis.disturbanceInAccF1, output_data.freqAnalysis.disturbanceInAccFS1Threshold, output_data.freqAnalysis.disturbanceInAccFS1Summed]...
                    = fftAnalysis(output_data.freqAnalysis.disturbanceTime, output_data.freqAnalysis.disturbanceInAcc, 0.9);
                [output_data.freqAnalysis.disturbanceEstInAccFS1, output_data.freqAnalysis.disturbanceEstInAccF1, output_data.freqAnalysis.disturbanceEstInAccFS1Threshold, output_data.freqAnalysis.disturbanceEstInAccFS1Summed]...
                    = fftAnalysis(output_data.freqAnalysis.disturbanceTime, output_data.freqAnalysis.disturbanceEstInAcc, 0.9);
            end
            
            if (obj.simopt.forward_kinematics_debugging)
                ctrl_fk_timevec   	=   obj.ctrl_fk_trajectory.timeVector';
                ctrl_fk_q         	=   cell2mat(obj.ctrl_fk_trajectory.q)';
                ctrl_fk_q_dot     	=   cell2mat(obj.ctrl_fk_trajectory.q_dot)';
                len_ctrl_fk = min([ size(ctrl_fk_timevec, 1), ...
                            size(ctrl_fk_q, 1), ...
                            size(ctrl_fk_q_dot, 1)]);
                ctrl_fk_timevec     =   ctrl_fk_timevec(1:len_ctrl_fk, :);
                ctrl_fk_q           =   ctrl_fk_q(1:len_ctrl_fk, :);
                ctrl_fk_q_dot       =   ctrl_fk_q_dot(1:len_ctrl_fk, :);
                
                output_data.DataFKTimeCtrl         	=   ctrl_fk_timevec;
                output_data.DataFKJointPoseCtrl    	=   ctrl_fk_q;
                output_data.DataFKJointVelocityCtrl	=   ctrl_fk_q_dot;
                
                ob_fk_timevec   	=   obj.ob_fk_trajectory.timeVector';
                ob_fk_q         	=   cell2mat(obj.ob_fk_trajectory.q)';
                ob_fk_q_dot     	=   cell2mat(obj.ob_fk_trajectory.q_dot)';
                len_ob_fk = min([ size(ob_fk_timevec, 1), ...
                            size(ob_fk_q, 1), ...
                            size(ob_fk_q_dot, 1)]);
                ob_fk_timevec     =   ob_fk_timevec(1:len_ob_fk, :);
                ob_fk_q           =   ob_fk_q(1:len_ob_fk, :);
                ob_fk_q_dot       =   ob_fk_q_dot(1:len_ob_fk, :);
                
                output_data.DataFKTimeOb         	=   ob_fk_timevec;
                output_data.DataFKJointPoseOb    	=   ob_fk_q;
                output_data.DataFKJointVelocityOb	=   ob_fk_q_dot;
            end
            output_data.compTime    =   obj.compTime;
            if (obj.simopt.is_operational_space_control)
                len_tmp = min([length(output_data.DataRefPose), length(output_data.DataSimOpPose)]);
                output_data.DataCtrlTrackingError = output_data.DataRefPose(1:len_tmp, :) - output_data.DataSimOpPose(1:len_tmp, :);
            else
                len_tmp = min([length(output_data.DataRefPose), length(output_data.DataCtrlJointPose)]);
                output_data.DataCtrlTrackingError = output_data.DataRefPose(1:len_tmp, :) - output_data.DataCtrlJointPose(1:len_tmp, :);
            end
            average_absolute_error = zeros(size(output_data.DataCtrlTrackingError, 2), 1);
            for i = 1:length(average_absolute_error)
                average_absolute_error(i) = norm(output_data.DataCtrlTrackingError(:,i), 1)/size(output_data.DataCtrlTrackingError, 1);
            end
            output_data.DataAvgCtrlTrackingError = average_absolute_error;
            average_force_command = zeros(size(output_data.DataCtrlForceCommands, 2), 1);
            for i = 1:length(average_force_command)
                average_force_command(i) = norm((output_data.DataCtrlForceCommands(:,i)), 1)/size(output_data.DataCtrlForceCommands, 1);
            end
            output_data.DataAvgCtrlForceCommand = average_force_command;
            output_data.DataAvgComputationalTime = norm(output_data.compTime, 1)/length(output_data.compTime);
        end
        
%         % Plots the tracking error in generalised coordinates
%         function plotTrackingError(obj, plot_axis)
%             trackingError_array = cell2mat(obj.stateError);
%             if(nargin == 1 || isempty(plot_axis)) 
%                 figure;
%                 plot(obj.timeVector, trackingError_array, 'Color', 'k', 'LineWidth', 1.5);
%             else
%                 plot(plot_axis, obj.timeVector, trackingError_array, 'Color', 'k', 'LineWidth', 1.5);
%             end
%         end
%         
%         % Plots both the reference and computed trajectory.
%         function plotJointSpaceTracking(obj, plot_axis, states_to_plot)
%             CASPR_log.Assert(~isempty(obj.trajectory), 'Cannot plot since trajectory is empty');
% 
%             n_dof = obj.model.numDofs;
% 
%             if nargin <= 2 || isempty(states_to_plot)
%                 states_to_plot = 1:n_dof;
%             end
% 
%             q_array = cell2mat(obj.trajectory.q);
%             q_dot_array = cell2mat(obj.trajectory.q_dot);
%             q_ref_array = cell2mat(obj.refTrajectory.q);
%             q_ref_dot_array = cell2mat(obj.refTrajectory.q_dot);
% 
%             if nargin <= 1 || isempty(plot_axis)
%                 % Plots joint space variables q(t)
%                 figure;
%                 hold on;
%                 plot(obj.timeVector, q_ref_array(states_to_plot, :), 'Color', 'r', 'LineStyle', '--', 'LineWidth', 1.5);
%                 plot(obj.timeVector, q_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
%                 hold off;
%                 title('Joint space variables');
% 
%                 % Plots derivative joint space variables q_dot(t)
%                 figure;
%                 hold on;
%                 plot(obj.timeVector, q_ref_dot_array(states_to_plot, :), 'Color', 'r', 'LineStyle', '--', 'LineWidth', 1.5);
%                 plot(obj.timeVector, q_dot_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
%                 hold off;
%                 title('Joint space derivatives');
%             else
%                 plot(plot_axis(1),obj.timeVector, q_ref_array(states_to_plot, :), 'LineWidth', 1.5, 'LineStyle', '--', 'Color', 'r'); 
%                 hold on;
%                 plot(plot_axis(1),obj.timeVector, q_array(states_to_plot, :), 'LineWidth', 1.5, 'Color', 'k'); 
%                 hold off;
%                 plot(plot_axis(2),obj.timeVector, q_ref_dot_array(states_to_plot, :), 'LineWidth', 'LineStyle', '--', 1.5, 'Color', 'r'); 
%                 hold on;
%                 plot(plot_axis(2),obj.timeVector, q_dot_array(states_to_plot, :), 'LineWidth', 1.5, 'Color', 'k'); 
%                 hold off;                
%             end
%         end
%         
%         % Plots both the reference and computed trajectory.
%         function plotSimJointSpaceTracking(obj, plot_axis, states_to_plot)
%             CASPR_log.Assert(~isempty(obj.sim_trajectory), 'Cannot plot since trajectory is empty');
% 
%             n_dof = obj.model.numDofs;
% 
%             if nargin <= 2 || isempty(states_to_plot)
%                 states_to_plot = 1:n_dof;
%             end
% 
%             q_array = cell2mat(obj.sim_trajectory.q);
%             q_dot_array = cell2mat(obj.sim_trajectory.q_dot);
%             q_ref_array = cell2mat(obj.refTrajectory.q);
%             q_ref_dot_array = cell2mat(obj.refTrajectory.q_dot);
% 
%             if nargin <= 1 || isempty(plot_axis)
%                 % Plots joint space variables q(t)
%                 figure;
%                 hold on;
%                 plot(obj.timeVector, q_ref_array(states_to_plot, :), 'Color', 'r', 'LineStyle', '--', 'LineWidth', 1.5);
%                 plot(obj.timeVector, q_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
%                 hold off;
%                 title('Joint space variables');
% 
%                 % Plots derivative joint space variables q_dot(t)
%                 figure;
%                 hold on;
%                 plot(obj.timeVector, q_ref_dot_array(states_to_plot, :), 'Color', 'r', 'LineStyle', '--', 'LineWidth', 1.5);
%                 plot(obj.timeVector, q_dot_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
%                 hold off;
%                 title('Joint space derivatives');
%             else
%                 plot(plot_axis(1),obj.timeVector, q_ref_array(states_to_plot, :), 'LineWidth', 1.5, 'LineStyle', '--', 'Color', 'r'); 
%                 hold on;
%                 plot(plot_axis(1),obj.timeVector, q_array(states_to_plot, :), 'LineWidth', 1.5, 'Color', 'k'); 
%                 hold off;
%                 plot(plot_axis(2),obj.timeVector, q_ref_dot_array(states_to_plot, :), 'LineWidth', 'LineStyle', '--', 1.5, 'Color', 'r'); 
%                 hold on;
%                 plot(plot_axis(2),obj.timeVector, q_dot_array(states_to_plot, :), 'LineWidth', 1.5, 'Color', 'k'); 
%                 hold off;                
%             end
%         end
    end
end
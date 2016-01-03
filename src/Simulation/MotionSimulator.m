classdef (Abstract) MotionSimulator < Simulator
    %DYNAMICSSIMULATION Summary of this class goes here
    %   Detailed explanation goes here
    
    properties
        timeVector          % time vector   
        trajectory      	% Trajectory object for inverse problems only
        lengths             % cell array of cable lengths
        lengths_dot         % cell array of cable lengths dot
    end
    
    methods
        function ms = MotionSimulator(model)
            ms@Simulator(model);
        end
        
        function plotMovie(obj, plot_axis, filename, time, width, height)      
            assert(~isempty(obj.trajectory), 'Cannot plot since trajectory is empty');
            
            fps = 30;
            
            writerObj = VideoWriter(filename);
            %writerObj.Quality = 100;
            writerObj.open();
            
            plot_handle = figure('Position', [10, 10, width, height]);
            for i = 1:round(fps*time)
                t = round(length(obj.timeVector)/round(fps*time)*i);
                if t == 0
                    t = 1;
                end
                obj.model.update(obj.trajectory.q{t}, obj.trajectory.q_dot{t}, obj.trajectory.q_ddot{t});
                MotionSimulator.PlotFrame(obj.model, plot_axis, plot_handle)
                frame = getframe(plot_handle);
                writerObj.writeVideo(frame);
                clf(plot_handle);
            end
            
            writerObj.close();
            close(plot_handle);
        end
        
        function plotCableLengths(obj, cables_to_plot)
            assert(~isempty(obj.lengths), 'Cannot plot since lengths vector is empty');
            assert(~isempty(obj.lengths_dot), 'Cannot plot since lengths_dot vector is empty');
            
            if nargin == 1 || isempty(cables_to_plot)
                cables_to_plot = 1:obj.model.numCables;
            end
            length_array = cell2mat(obj.lengths);
            length_dot_array = cell2mat(obj.lengths_dot);
            
            figure;
            plot(obj.timeVector, length_array(cables_to_plot, :), 'LineWidth', 1.5, 'Color', 'k');
            title('Cable Lengths'); 
            
            figure;
            plot(obj.timeVector, length_dot_array(cables_to_plot, :), 'LineWidth', 1.5, 'Color', 'k');
            title('Cable Lengths Derivative'); 
            
            % ONLY USED IN DEBUGGING START
%             lengths_dot_num = zeros(obj.model.numCables, length(obj.timeVector));
%             for t = 2:length(obj.timeVector)
%                 lengths_dot_num(:, t) = (length_array(:, t) - length_array(:, t-1))/(obj.timeVector(t) - obj.timeVector(t-1));
%             end
%             figure; 
%             plot(obj.timeVector, lengths_dot_num(cables_to_plot, :), 'LineWidth', 1.5, 'Color', 'k');   
%             title('Cable Lengths Derivative (Numerical)');     
            % ONLY USED IN DEBUGGING END   
        end
        
        function plotJointSpace(obj, states_to_plot)            
            assert(~isempty(obj.trajectory), 'Cannot plot since trajectory is empty');
            
            n_dof = obj.model.numDofs;
            
            if nargin == 1 || isempty(states_to_plot)
                states_to_plot = 1:n_dof;
            end
            
            q_array = cell2mat(obj.trajectory.q);
            q_dot_array = cell2mat(obj.trajectory.q_dot);
            
            % Plots joint space variables q(t)
            figure;
            plot(obj.timeVector, q_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
            title('Joint space variables');
            
            % Plots derivative joint space variables q_dot(t)
            figure;
            plot(obj.timeVector, q_dot_array(states_to_plot, :), 'Color', 'k', 'LineWidth', 1.5);
            title('Joint space derivatives');
        end
        
        function plotBodyCOG(obj, bodies_to_plot)            
            assert(~isempty(obj.trajectory), 'Cannot plot since trajectory is empty');
            
            % Plots absolute position, velocity and acceleration of COG
            % with respect to {0}
            if nargin == 1 || isempty(bodies_to_plot)
                bodies_to_plot = 1:obj.model.numLinks;
            end
            
            pos0 = zeros(3*length(bodies_to_plot), length(obj.timeVector));
            pos0_dot = zeros(3*length(bodies_to_plot), length(obj.timeVector));
            pos0_ddot = zeros(3*length(bodies_to_plot), length(obj.timeVector));
            for t = 1:length(obj.timeVector)
                obj.model.bodyKinematics.update(obj.trajectory.q{t}, obj.trajectory.q_dot{t}, obj.trajectory.q_ddot{t});
                for ki = 1:length(bodies_to_plot)
                    pos0(3*ki-2:3*ki, t) = obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.R_0k*obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.r_OG;
                    pos0_dot(3*ki-2:3*ki, t) = obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.R_0k*obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.v_OG;
                    pos0_ddot(3*ki-2:3*ki, t) = obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.R_0k*obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.a_OG;
                end
            end
            figure; 
            plot(obj.timeVector, pos0, 'Color', 'k', 'LineWidth', 1.5);
            title('Position of CoG');
            
            figure; 
            plot(obj.timeVector, pos0_dot, 'Color', 'k', 'LineWidth', 1.5);
            title('Velocity of CoG');
            
            figure; 
            plot(obj.timeVector, pos0_ddot, 'Color', 'k', 'LineWidth', 1.5);
            title('Acceleration of CoG');
                        
            % ONLY USED IN DEBUGGING START
            % Numerical derivative must be performed in frame {0}
%             pos0_dot_num = zeros(size(pos0));
%             pos0_ddot_num = zeros(size(pos0));
%             for t = 2:length(obj.timeVector)
%                 pos0_dot_num(:, t) = (pos0(:, t) - pos0(:, t-1))/(obj.timeVector(t)-obj.timeVector(t-1));
%                 pos0_ddot_num(:, t) = (pos0_dot_num(:, t) - pos0_dot_num(:, t-1))/(obj.timeVector(t)-obj.timeVector(t-1));
%             end
%             figure;
%             plot(obj.timeVector, pos0_dot_num, 'Color', 'k', 'LineWidth', 1.5);
%             title('Velocity of CoG (numerical)');
%             figure;
%             plot(obj.timeVector, pos0_ddot_num, 'Color', 'k', 'LineWidth', 1.5);
%             title('Acceleration of CoG (numerical)');
            % ONLY USED IN DEBUGGING END
        end
        
        function plotAngularAcceleration(obj, bodies_to_plot)
            assert(~isempty(obj.trajectory), 'Cannot plot since trajectory is empty');
            
            % Plots absolute position, velocity and acceleration of COG
            % with respect to {0}            
            if nargin == 1 || isempty(bodies_to_plot)
                bodies_to_plot = 1:obj.model.numLinks;
            end
            
            ang0 = zeros(3*length(bodies_to_plot), length(obj.timeVector));
            ang0_dot = zeros(3*length(bodies_to_plot), length(obj.timeVector));
            for t = 1:length(obj.timeVector)
                obj.model.bodyKinematics.update(obj.trajectory.q{t}, obj.trajectory.q_dot{t}, obj.trajectory.q_ddot{t});
                for ki = 1:length(bodies_to_plot)
                    ang0(3*ki-2:3*ki, t) = obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.R_0k*obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.w;
                    ang0_dot(3*ki-2:3*ki, t) = obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.R_0k*obj.model.bodyKinematics.bodies{bodies_to_plot(ki)}.w_dot;
                end
            end
            
            figure;
            plot(obj.timeVector, ang0, 'Color', 'k', 'LineWidth', 1.5);
            title('Angular velocity of rigid bodies');
            
            figure;
            plot(obj.timeVector, ang0_dot, 'Color', 'k', 'LineWidth', 1.5);
            title('Angular acceleration of rigid bodies');
            
            % ONLY USED IN DEBUGGING START
%             % Numerical derivative must be performed in frame {0}
%             ang0_dot_num = zeros(size(ang0));
%             for t = 2:length(obj.timeVector)
%                 ang0_dot_num(:, t) = (ang0(:, t) - ang0(:, t-1))/(obj.timeVector(t)-obj.timeVector(t-1));
%             end
%             figure; 
%             plot(obj.timeVector, ang0_dot_num, 'Color', 'k');
%             title('Aangular acceleration of rigid bodies (numerical)');
            % ONLY USED IN DEBUGGING START
        end
            
    end
    methods (Static)        
        function PlotFrame(kinematics, plot_axis, fig_handle)
            if nargin < 3
                fig_handle = figure;
            end
            
            figure(fig_handle);
            axis equal;
            axis(plot_axis);
            hold on;
            grid on;
            xlabel('x');
            ylabel('y');
            
            body_kinematics = kinematics.bodyKinematics;
            for k = 1:body_kinematics.numLinks
                r_OP0 = body_kinematics.bodies{k}.R_0k*body_kinematics.bodies{k}.r_OP;
                r_OG0 = body_kinematics.bodies{k}.R_0k*body_kinematics.bodies{k}.r_OG;
                r_OPe0 = body_kinematics.bodies{k}.R_0k*body_kinematics.bodies{k}.r_OPe;
                plot3(r_OP0(1), r_OP0(2), r_OP0(3), 'Color', 'k', 'Marker', 'o', 'LineWidth', 2);
                plot3(r_OG0(1), r_OG0(2), r_OG0(3), 'Color', 'b', 'Marker', 'o', 'LineWidth', 2);
                line([r_OP0(1) r_OPe0(1)], [r_OP0(2) r_OPe0(2)], [r_OP0(3) r_OPe0(3)], 'Color', 'k', 'LineWidth', 3);
            end
            
            cable_kinematics = kinematics.cableKinematics;
            for i = 1:cable_kinematics.numCables
                for j = 1:cable_kinematics.cables{i}.numSegments
                    for k = 1:cable_kinematics.numLinks+1
                        if cable_kinematics.getCRMTerm(i,j,k) == -1
                            r_OAa0 = cable_kinematics.cables{i}.segments{j}.r_OA{k};
                            if k > 1
                                r_OAa0 = body_kinematics.bodies{k-1}.R_0k*r_OAa0;
                            end
                        elseif cable_kinematics.getCRMTerm(i,j,k) == 1
                            r_OAb0 = cable_kinematics.cables{i}.segments{j}.r_OA{k};
                            if k > 1
                                r_OAb0 = body_kinematics.bodies{k-1}.R_0k*r_OAb0;
                            end
                        end
                    end
                    line([r_OAa0(1) r_OAb0(1)], [r_OAa0(2) r_OAb0(2)], [r_OAa0(3) r_OAb0(3)], 'Color', 'r', 'LineWidth', 1);
                end
            end
            
            hold off;
        end
    end    
end

